//! The Rust side of the agent browser's engine binding.
//!
//! The crate owns the `WebviewProvider`, implements formal-web's `Embedder`
//! trait by forwarding every callback into Swift, and exposes the provider's
//! entry points through a small C ABI. It also owns the CDP server: the
//! `AutomationHost` implementation lives on one dedicated automation thread,
//! and the server's `Agent` domain is routed to the Swift agent loop through
//! the domain-call callback.
//!
//! The API is asynchronous. `agentbrowser_start` asks the engine to start and
//! returns; the webview arrives through `new_webview`, navigation through
//! `navigation_completed`, and pixels through `layers`. Swift stores the
//! webview key and passes it back to the action entry points. The automation
//! thread is the only owner of the automation controller and host; commands
//! reach it over a channel, which is the same message-passing shape the
//! AppKit embedder uses for its event loop.
//!
//! All pointers in the C ABI are borrowed for the duration of a call unless a
//! function says otherwise. A returned string or byte buffer is allocated by
//! Swift and released through the matching free callback.

use automation::{
    AutomationCommand, AutomationController, AutomationHost, AutomationRuntime, AutomationSnapshot,
    AutomationVisibleFrameViewport, CdpDomainHandler, CdpEvent, CdpServerHandle,
};
use ipc_messages::content::NavigableId;
use keyboard_types::{Code, Key, Location, Modifiers, NamedKey};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char, c_void};
use std::os::raw::c_uchar;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use webview::{
    BlitzImeEvent, BlitzKeyEvent, BlitzPointerEvent, BlitzPointerId, BlitzWheelDelta,
    BlitzWheelEvent, ColorScheme, CompositionKind, Embedder, EmbedderConfig,
    EmbedderSchemeRequest, KeyState, LayerFrame, MouseEventButton, MouseEventButtons,
    NavigationCompleted, NavigationCompletion, Point, PointerCoords, PointerDetails, SurfaceFrame,
    UiEvent, WebviewId, WebviewProvider,
};

/// One layer handed to Swift. `topology_json` is a NUL-terminated JSON object
/// valid only during the callback; `bytes` is either absent (shared texture)
/// or the CPU RGBA readback valid only during the callback.
#[repr(C)]
pub struct AbiLayer {
    pub topology_json: *const c_char,
    pub width: u32,
    pub height: u32,
    /// 0 = no surface (a clean layer), 1 = shared IOSurface, 2 = CPU bytes.
    pub surface_kind: u8,
    pub surface_id: u32,
    /// Mach port (send right) to the shared IOSurface, for the fallback
    /// lookup when the global ID is not resolvable. Swift owns this right
    /// and deallocates it after the lookup.
    pub surface_port: u32,
    pub texture_id: u64,
    pub bytes: *const c_uchar,
    pub byte_len: usize,
    pub bytes_per_row: usize,
}

pub type NavigationFn = extern "C" fn(*mut c_void, *const c_char, *const c_char);
pub type WebviewFn = extern "C" fn(*mut c_void, *const c_char, *const c_char);
pub type FrameFn = extern "C" fn(*mut c_void, *const c_char);
pub type ScaleFn = extern "C" fn(*mut c_void) -> f32;
pub type ViewportFn = extern "C" fn(*mut c_void, *mut u32, *mut u32, *mut f32, *mut u8) -> bool;
pub type TextFn = extern "C" fn(*mut c_void, *const c_char);
pub type HostMessageFn = extern "C" fn(*mut c_void, *const c_char, *const c_char, *const c_char);
pub type LayersFn = extern "C" fn(
    *mut c_void,
    *const c_char,
    *const AbiLayer,
    usize,
    bool,
    i32,
);
pub type ScreenshotFn = extern "C" fn(*mut c_void, *mut usize) -> *mut c_uchar;
pub type DomainCallFn = extern "C" fn(*mut c_void, *const c_char, *const c_char) -> *mut c_char;
pub type FreeStringFn = extern "C" fn(*mut c_char);
pub type FreeBytesFn = extern "C" fn(*mut c_uchar, usize);
pub type LogFn = extern "C" fn(*mut c_void, i32, *const c_char);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AbiCallbacks {
    pub context: *mut c_void,
    pub navigation_requested: Option<NavigationFn>,
    pub navigation_completed: Option<NavigationFn>,
    pub new_webview: Option<WebviewFn>,
    pub request_next_frame: Option<FrameFn>,
    pub viewport_scale_factor: Option<ScaleFn>,
    pub window_viewport: Option<ViewportFn>,
    pub clipboard_set_text: Option<TextFn>,
    pub host_message: Option<HostMessageFn>,
    pub title_changed: Option<WebviewFn>,
    pub layers: Option<LayersFn>,
    pub screenshot: Option<ScreenshotFn>,
    pub domain_call: Option<DomainCallFn>,
    pub free_string: Option<FreeStringFn>,
    pub free_bytes: Option<FreeBytesFn>,
    pub log: Option<LogFn>,
}

// SAFETY: `context` is a Swift object the app keeps alive for the whole engine
// and makes safe to call from any thread (Swift guards it with a lock). Every
// function pointer is a plain C function with no captured state. The raw
// pointer is only a token; no Rust code dereferences it.
unsafe impl Send for AbiCallbacks {}
// SAFETY: see the `Send` impl; sharing the token across threads is the same
// contract.
unsafe impl Sync for AbiCallbacks {}

impl AbiCallbacks {
    fn string(&self, pointer: *const c_char) -> String {
        if pointer.is_null() {
            return String::new();
        }
        // SAFETY: the C ABI says a string pointer is NUL-terminated and valid
        // for the duration of the call.
        unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned()
    }

    fn send_string(&self, function: Option<TextFn>, text: &str) {
        let Some(function) = function else { return };
        let Ok(text) = CString::new(text) else { return };
        function(self.context, text.as_ptr());
    }

    fn send_webview_string(&self, function: Option<WebviewFn>, webview: WebviewId, text: &str) {
        let Some(function) = function else { return };
        let Ok(webview) = CString::new(webview.0.to_string()) else {
            return;
        };
        let Ok(text) = CString::new(text) else { return };
        function(self.context, webview.as_ptr(), text.as_ptr());
    }

    fn log(&self, level: i32, message: &str) {
        let Some(function) = self.log else { return };
        let Ok(message) = CString::new(message) else { return };
        function(self.context, level, message.as_ptr());
    }

    fn string_from_swift(&self, pointer: *mut c_char) -> String {
        if pointer.is_null() {
            return String::new();
        }
        // SAFETY: the callback contract says the returned pointer is a
        // NUL-terminated string that stays valid until `free_string` is called.
        let text = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        if let Some(free) = self.free_string {
            free(pointer);
        }
        text
    }
}

struct BindingEmbedder {
    callbacks: AbiCallbacks,
    automation: std::sync::mpsc::Sender<AutomationCommand>,
}

impl Embedder for BindingEmbedder {
    fn navigation_requested(
        &self,
        webview_id: WebviewId,
        destination_url: String,
    ) -> Result<(), String> {
        if let Some(function) = self.callbacks.navigation_requested {
            let Ok(webview) = CString::new(webview_id.0.to_string()) else {
                return Ok(());
            };
            let Ok(url) = CString::new(destination_url) else {
                return Ok(());
            };
            function(self.callbacks.context, webview.as_ptr(), url.as_ptr());
        }
        Ok(())
    }

    fn navigation_completed(&self, completed: NavigationCompleted) -> Result<(), String> {
        let url = match completed.status {
            NavigationCompletion::Committed { url } => url,
            NavigationCompletion::Aborted { message } => {
                self.callbacks
                    .log(1, &format!("navigation aborted: {message}"));
                String::new()
            }
        };
        self.callbacks.send_webview_string(
            self.callbacks.navigation_completed,
            completed.webview_id,
            &url,
        );
        let _ = self
            .automation
            .send(AutomationCommand::NavigationCommitted { url });
        Ok(())
    }

    fn new_webview(&self, webview_id: WebviewId, target_name: String) -> Result<(), String> {
        self.callbacks
            .send_webview_string(self.callbacks.new_webview, webview_id, &target_name);
        let _ = self
            .automation
            .send(AutomationCommand::SetWebview { webview_id });
        Ok(())
    }

    fn request_next_frame(&self, webview_id: WebviewId) {
        if let Some(function) = self.callbacks.request_next_frame {
            let Ok(webview) = CString::new(webview_id.0.to_string()) else {
                return;
            };
            function(self.callbacks.context, webview.as_ptr());
        }
    }

    fn viewport_scale_factor(&self) -> f32 {
        match self.callbacks.viewport_scale_factor {
            Some(function) => function(self.callbacks.context),
            None => 1.0,
        }
    }

    fn window_viewport_snapshot(&self) -> Option<(u32, u32, f32, ColorScheme)> {
        let mut width = 0;
        let mut height = 0;
        let mut scale = 1.0;
        let mut scheme = 0_u8;
        let function = self.callbacks.window_viewport?;
        let ok = function(
            self.callbacks.context,
            &mut width,
            &mut height,
            &mut scale,
            &mut scheme,
        );
        if !ok || width == 0 || height == 0 {
            return None;
        }
        let scheme = if scheme == 1 {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        };
        Some((width, height, scale, scheme))
    }

    fn clipboard_set_text(&self, text: String) {
        self.callbacks
            .send_string(self.callbacks.clipboard_set_text, &text);
    }

    fn embedder_scheme_fetch(&self, _webview_id: WebviewId, _request: EmbedderSchemeRequest) {}

    fn host_message(&self, webview_id: WebviewId, url: String, body: String) -> Result<(), String> {
        if let Some(function) = self.callbacks.host_message {
            let Ok(webview) = CString::new(webview_id.0.to_string()) else {
                return Ok(());
            };
            let Ok(url) = CString::new(url) else { return Ok(()) };
            let Ok(body) = CString::new(body) else { return Ok(()) };
            function(
                self.callbacks.context,
                webview.as_ptr(),
                url.as_ptr(),
                body.as_ptr(),
            );
        }
        Ok(())
    }

    fn title_changed(&self, webview_id: WebviewId, title: String) -> Result<(), String> {
        self.callbacks
            .send_webview_string(self.callbacks.title_changed, webview_id, &title);
        Ok(())
    }

    fn new_web_content_layers(
        &self,
        webview_id: WebviewId,
        layers: Vec<LayerFrame>,
        animating: bool,
        composition_kind: CompositionKind,
    ) -> Result<(), String> {
        let Some(function) = self.callbacks.layers else {
            return Ok(());
        };
        let mut abi_layers = Vec::with_capacity(layers.len());
        let mut topology_strings = Vec::with_capacity(layers.len());
        for layer in &layers {
            let topology = &layer.topology;
            let layer_id = layer_id_string(topology.layer_id);
            let parent = topology.parent.map(layer_id_string);
            let json = json!({
                "layer_id": layer_id,
                "parent": parent,
                "transform": topology.transform,
                "clip_bounds": topology.clip_bounds,
                "corner_radius": topology.corner_radius,
                "z_order": topology.z_order,
                "width": topology.width,
                "height": topology.height,
                "background": topology.background.as_ref().map(|background| format!("{background:?}")),
            })
            .to_string();
            let topology_string = CString::new(json).map_err(|error| error.to_string())?;
            let mut surface_kind = 0;
            let mut surface_id = 0;
            let mut surface_port = 0;
            let mut texture_id = 0;
            let mut bytes_ptr = std::ptr::null();
            let mut byte_len = 0;
            let mut bytes_per_row = 0;
            match &layer.frame {
                Some(SurfaceFrame::SharedTexture {
                    surface_id: id,
                    texture_id: texture,
                    port,
                }) => {
                    surface_kind = 1;
                    surface_id = *id;
                    // The frame keeps its own port; hand Swift a cloned send
                    // right that it deallocates after the fallback lookup.
                    surface_port = port.clone().into_name();
                    texture_id = *texture;
                }
                Some(SurfaceFrame::CpuShmem(region)) => {
                    surface_kind = 2;
                    let bytes = region.as_slice();
                    bytes_ptr = bytes.as_ptr();
                    byte_len = bytes.len();
                    bytes_per_row = (topology.width as usize).saturating_mul(4);
                }
                None => {}
            }
            abi_layers.push(AbiLayer {
                topology_json: topology_string.as_ptr(),
                width: topology.width,
                height: topology.height,
                surface_kind,
                surface_id,
                surface_port,
                texture_id,
                bytes: bytes_ptr,
                byte_len,
                bytes_per_row,
            });
            topology_strings.push(topology_string);
        }
        let Ok(webview) = CString::new(webview_id.0.to_string()) else {
            return Ok(());
        };
        function(
            self.callbacks.context,
            webview.as_ptr(),
            abi_layers.as_ptr(),
            abi_layers.len(),
            animating,
            match composition_kind {
                CompositionKind::ContentUpdate => 0,
                CompositionKind::Deadline => 1,
                CompositionKind::OutOfBand => 2,
            },
        );
        Ok(())
    }
}

fn layer_id_string(layer_id: webview::CompositingLayerId) -> String {
    match layer_id {
        webview::CompositingLayerId::Navigable(frame) => format!("navigable:{frame:?}"),
        webview::CompositingLayerId::Video(video) => format!("video:{video:?}"),
        webview::CompositingLayerId::Canvas(canvas) => format!("canvas:{canvas:?}"),
        webview::CompositingLayerId::Image(image) => format!("image:{image:?}"),
    }
}

struct BindingAutomationHost {
    provider: Arc<WebviewProvider>,
    callbacks: AbiCallbacks,
    webview_id: Option<WebviewId>,
    committed_url: String,
}

impl AutomationHost for BindingAutomationHost {
    fn automation_snapshot(&mut self) -> AutomationSnapshot {
        AutomationSnapshot {
            webview_id: self.webview_id,
            current_url: (!self.committed_url.is_empty()).then(|| self.committed_url.clone()),
            displayed_url: self.committed_url.clone(),
            navigable_id: None,
            has_top_level_traversable: self.webview_id.is_some(),
        }
    }

    fn automation_visible_frame_viewports(
        &mut self,
    ) -> Result<Vec<AutomationVisibleFrameViewport>, String> {
        Ok(Vec::new())
    }

    fn automation_screenshot(&mut self) -> Result<Vec<u8>, String> {
        let Some(function) = self.callbacks.screenshot else {
            return Err(String::from("the embedder supplied no screenshot callback"));
        };
        let mut length = 0_usize;
        let pointer = function(self.callbacks.context, &mut length);
        if pointer.is_null() || length == 0 {
            return Err(String::from("the embedder returned no screenshot"));
        }
        // SAFETY: the callback contract says the pointer covers `length`
        // initialized bytes until `free_bytes` is called.
        let bytes = unsafe { std::slice::from_raw_parts(pointer, length) }.to_vec();
        if let Some(free) = self.callbacks.free_bytes {
            free(pointer, length);
        }
        Ok(bytes)
    }

    fn begin_automation_navigation(&mut self, url: String) -> Result<(), String> {
        self.provider.navigate(self.webview_id, &url)
    }

    fn automation_click(&mut self, x: f32, y: f32) -> Result<(), String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        let coords = pointer_coords(x, y);
        let mut buttons = MouseEventButtons::None;
        send_pointer(&self.provider, webview_id, coords, buttons, UiEventKind::Move)?;
        buttons |= MouseEventButton::Main.into();
        send_pointer(&self.provider, webview_id, coords, buttons, UiEventKind::Down)?;
        buttons.remove(MouseEventButton::Main.into());
        send_pointer(&self.provider, webview_id, coords, buttons, UiEventKind::Up)
    }

    fn automation_click_element(&mut self, selector: String) -> Result<(), String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        self.provider.click_element(webview_id, selector)
    }

    fn automation_scroll(
        &mut self,
        x: f32,
        y: f32,
        delta_x: f32,
        delta_y: f32,
    ) -> Result<(), String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        let coords = pointer_coords(x, y);
        send_pointer(
            &self.provider,
            webview_id,
            coords,
            MouseEventButtons::None,
            UiEventKind::Move,
        )?;
        self.provider.send_ui_event(
            webview_id,
            UiEvent::Wheel(BlitzWheelEvent {
                delta: BlitzWheelDelta::Pixels(f64::from(delta_x), f64::from(delta_y)),
                coords,
                buttons: MouseEventButtons::None,
                mods: Modifiers::default(),
                element: Point { x: 0.0, y: 0.0 },
            }),
        )
    }

    fn automation_evaluate_script(
        &mut self,
        source: String,
        timeout: Duration,
    ) -> Result<Value, String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        self.provider.evaluate_script(webview_id, source, timeout)
    }

    fn automation_key(
        &mut self,
        event_type: &str,
        key: &str,
        code: &str,
        text: Option<&str>,
        modifiers: u32,
    ) -> Result<(), String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        if event_type == "char" {
            if let Some(text) = text.filter(|text| !text.is_empty()) {
                return self.provider.send_ui_event(
                    webview_id,
                    UiEvent::Ime(BlitzImeEvent::Commit(text.to_owned())),
                );
            }
            return Ok(());
        }
        let state = if event_type == "keyUp" {
            KeyState::Released
        } else {
            KeyState::Pressed
        };
        let event = BlitzKeyEvent {
            key: key_value(key, text),
            code: code.parse().unwrap_or(Code::Unidentified),
            modifiers: modifiers_from_bits(modifiers),
            location: Location::Standard,
            is_auto_repeating: false,
            is_composing: false,
            state,
            text: text.map(|text| text.to_owned().into()),
        };
        let event = if state == KeyState::Pressed {
            UiEvent::KeyDown(event)
        } else {
            UiEvent::KeyUp(event)
        };
        self.provider.send_ui_event(webview_id, event)
    }

    fn automation_insert_text(&mut self, text: &str) -> Result<(), String> {
        let webview_id = self
            .webview_id
            .ok_or_else(|| String::from("no webview"))?;
        self.provider
            .send_ui_event(webview_id, UiEvent::Ime(BlitzImeEvent::Commit(text.to_owned())))
    }

    fn automation_set_webview(&mut self, webview_id: WebviewId) {
        self.webview_id = Some(webview_id);
    }

    fn automation_navigation_committed(&mut self, url: String) {
        self.committed_url = url;
    }
}

fn key_value(key: &str, text: Option<&str>) -> Key {
    if key.is_empty()
        && let Some(text) = text.filter(|text| !text.is_empty())
    {
        return Key::Character(text.to_owned());
    }
    if key.chars().count() == 1 {
        return Key::Character(key.to_owned());
    }
    key.parse::<Key>()
        .or_else(|_| key.parse::<NamedKey>().map(Key::Named))
        .unwrap_or(Key::Named(NamedKey::Unidentified))
}

fn modifiers_from_bits(bits: u32) -> Modifiers {
    let mut modifiers = Modifiers::default();
    if bits & Modifiers::CONTROL.bits() != 0 {
        modifiers.insert(Modifiers::CONTROL);
    }
    if bits & Modifiers::ALT.bits() != 0 {
        modifiers.insert(Modifiers::ALT);
    }
    if bits & Modifiers::SHIFT.bits() != 0 {
        modifiers.insert(Modifiers::SHIFT);
    }
    if bits & Modifiers::META.bits() != 0 {
        modifiers.insert(Modifiers::META);
    }
    modifiers
}

#[derive(Clone, Copy)]
enum UiEventKind {
    Move,
    Down,
    Up,
}

fn pointer_coords(x: f32, y: f32) -> PointerCoords {
    PointerCoords {
        page_x: x,
        page_y: y,
        screen_x: x,
        screen_y: y,
        client_x: x,
        client_y: y,
    }
}

fn send_pointer(
    provider: &WebviewProvider,
    webview_id: WebviewId,
    coords: PointerCoords,
    buttons: MouseEventButtons,
    kind: UiEventKind,
) -> Result<(), String> {
    let event = BlitzPointerEvent {
        id: BlitzPointerId::Mouse,
        is_primary: true,
        coords,
        button: MouseEventButton::Main,
        buttons,
        mods: Modifiers::default(),
        details: PointerDetails::default(),
        element: Point { x: 0.0, y: 0.0 },
        active_pointers: Default::default(),
    };
    let event = match kind {
        UiEventKind::Move => UiEvent::PointerMove(event),
        UiEventKind::Down => UiEvent::PointerDown(event),
        UiEventKind::Up => UiEvent::PointerUp(event),
    };
    provider.send_ui_event(webview_id, event)
}

struct SwiftDomainHandler {
    callbacks: AbiCallbacks,
}

impl CdpDomainHandler for SwiftDomainHandler {
    fn handle_cdp_call(&self, method: &str, params: Value) -> Result<Value, String> {
        let Some(function) = self.callbacks.domain_call else {
            return Ok(json!({}));
        };
        let Ok(method_c) = CString::new(method) else {
            return Err(String::from("CDP method name contains a NUL"));
        };
        let Ok(params_c) = CString::new(params.to_string()) else {
            return Err(String::from("CDP params contain a NUL"));
        };
        let pointer = function(self.callbacks.context, method_c.as_ptr(), params_c.as_ptr());
        let text = self.callbacks.string_from_swift(pointer);
        if text.is_empty() {
            return Ok(json!({}));
        }
        serde_json::from_str(&text).map_err(|error| format!("invalid domain response: {error}"))
    }
}

pub struct Engine {
    provider: Arc<WebviewProvider>,
    callbacks: AbiCallbacks,
    _cdp_server: Option<CdpServerHandle>,
    runtime: AutomationRuntime,
    automation_stop: Arc<AtomicBool>,
    automation_thread: Option<std::thread::JoinHandle<()>>,
}

/// Create the engine. `extensions_directory` is the directory holding the
/// three helper executables. `cdp_port` is zero when the endpoint is off.
///
/// # Safety
/// `callbacks.context` and every function pointer must stay valid until
/// `agentbrowser_destroy` returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_create(
    extensions_directory: *const c_char,
    cdp_port: u16,
    callbacks: AbiCallbacks,
) -> *mut Engine {
    if let Err(error) = env_logger::try_init() {
        eprintln!("agent-browser-engine: logger already initialized: {error}");
    }
    let extensions_directory = if extensions_directory.is_null() {
        None
    } else {
        // SAFETY: the caller passes a NUL-terminated path or null; the pointer
        // is read only here and never retained.
        Some(std::path::PathBuf::from(
            unsafe { CStr::from_ptr(extensions_directory) }
                .to_string_lossy()
                .into_owned(),
        ))
    };
    let (automation_sender, automation_receiver) = std::sync::mpsc::channel::<AutomationCommand>();
    let embedder = Arc::new(BindingEmbedder {
        callbacks,
        automation: automation_sender.clone(),
    });
    let config = EmbedderConfig {
        extensions_directory,
        ..EmbedderConfig::default()
    };
    let provider = match WebviewProvider::new(embedder, None, config) {
        Ok(provider) => Arc::new(provider),
        Err(error) => {
            callbacks.log(0, &format!("failed to start the engine: {error}"));
            return std::ptr::null_mut();
        }
    };

    let runtime = AutomationRuntime::new(
        move |command| {
            automation_sender
                .send(command)
                .map_err(|error| format!("automation command channel closed: {error}"))
        },
        || Ok(()),
        || true,
    )
    .with_cdp_domain_handler(Arc::new(SwiftDomainHandler { callbacks }));

    let automation_stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&automation_stop);
    let automation_host = BindingAutomationHost {
        provider: Arc::clone(&provider),
        callbacks,
        webview_id: None,
        committed_url: String::new(),
    };
    let automation_thread = match std::thread::Builder::new()
        .name(String::from("agent-browser-automation"))
        .spawn(move || {
            let mut controller = AutomationController::default();
            let mut host = automation_host;
            loop {
                match automation_receiver.recv_timeout(Duration::from_millis(200)) {
                    Ok(command) => controller.handle_command(&mut host, command),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if thread_stop.load(Ordering::SeqCst) {
                            break;
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            // Dropping the host releases its provider Arc; when the engine has
            // already dropped its own Arc, this is what runs UserAgent::drop
            // and shuts down the helper processes.
        }) {
        Ok(thread) => thread,
        Err(error) => {
            callbacks.log(0, &format!("failed to start automation thread: {error}"));
            return std::ptr::null_mut();
        }
    };

    let cdp_server = if cdp_port != 0 {
        match CdpServerHandle::start(cdp_port, runtime.clone()) {
            Ok(server) => {
                callbacks.log(0, &format!("CDP server listening on 127.0.0.1:{cdp_port}"));
                Some(server)
            }
            Err(error) => {
                callbacks.log(0, &format!("failed to start CDP server: {error}"));
                None
            }
        }
    } else {
        None
    };

    Box::into_raw(Box::new(Engine {
        provider,
        callbacks,
        _cdp_server: cdp_server,
        runtime,
        automation_stop,
        automation_thread: Some(automation_thread),
    }))
}

fn engine<'a>(pointer: *mut Engine) -> Option<&'a Engine> {
    // SAFETY: every C entry point has the same contract: `pointer` is a live
    // handle returned by `agentbrowser_create` and is not destroyed during the
    // call.
    unsafe { pointer.as_ref() }
}

fn webview(engine: &Engine, pointer: *const c_char) -> Option<WebviewId> {
    let text = engine.callbacks.string(pointer);
    NavigableId::parse_str(&text).ok().map(WebviewId)
}

/// Start the first webview. The webview arrives through `new_webview`; this
/// function does not wait for it.
///
/// # Safety
/// `engine` must be a live pointer returned by `agentbrowser_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_start(engine_pointer: *mut Engine, url: *const c_char) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let url = (!url.is_null()).then(|| engine.callbacks.string(url));
    match engine.provider.start(url.as_deref(), Vec::new()) {
        Ok(()) => true,
        Err(error) => {
            engine
                .callbacks
                .log(0, &format!("failed to start the webview: {error}"));
            false
        }
    }
}

/// Set the default viewport before the first webview exists.
///
/// # Safety
/// `engine` must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_set_default_viewport(
    engine_pointer: *mut Engine,
    width: u32,
    height: u32,
    scale: f32,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    engine
        .provider
        .set_default_viewport(Some((width, height, scale, ColorScheme::Light)))
        .is_ok()
}

/// Update the traversable viewport.
///
/// # Safety
/// `engine` must be live and `webview` NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_set_viewport(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
    width: u32,
    height: u32,
    scale: f32,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    engine
        .provider
        .set_traversable_viewport(
            webview_id,
            (width, height, scale, ColorScheme::Light),
            0.0,
            0.0,
        )
        .is_ok()
}

/// Navigate the agent tab.
///
/// # Safety
/// `engine` must be live; the strings are NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_navigate(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
    url: *const c_char,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    engine
        .provider
        .navigate(Some(webview_id), &engine.callbacks.string(url))
        .is_ok()
}

/// Raise one rendering opportunity.
///
/// # Safety
/// `engine` must be live and `webview` NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_frame_needed(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
    display_deadline_ms: i64,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    let deadline = (display_deadline_ms > 0)
        .then(|| Duration::from_millis(display_deadline_ms as u64));
    engine.provider.frame_needed(webview_id, deadline).is_ok()
}

/// Send one serialized UI event.
///
/// # Safety
/// `engine` must be live; the strings are NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_send_ui_event(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
    json: *const c_char,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    let Ok(event) = serde_json::from_str::<UiEventJson>(&engine.callbacks.string(json)) else {
        engine.callbacks.log(0, "invalid UI event JSON");
        return false;
    };
    match event.into_ui_event() {
        Ok(event) => engine.provider.send_ui_event(webview_id, event).is_ok(),
        Err(error) => {
            engine.callbacks.log(0, &error);
            false
        }
    }
}

/// Evaluate a script in the agent tab. Returns a Rust-owned JSON string; free
/// it with `agentbrowser_free_string`.
///
/// # Safety
/// `engine` must be live; the strings are NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_evaluate(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
    source: *const c_char,
    timeout_ms: u64,
) -> *mut c_char {
    let Some(engine) = engine(engine_pointer) else {
        return std::ptr::null_mut();
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return std::ptr::null_mut();
    };
    match engine.provider.evaluate_script(
        webview_id,
        engine.callbacks.string(source),
        Duration::from_millis(timeout_ms.max(1)),
    ) {
        Ok(value) => CString::new(value.to_string())
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut()),
        Err(error) => {
            engine.callbacks.log(0, &error);
            std::ptr::null_mut()
        }
    }
}

/// Free a string returned by `agentbrowser_evaluate`.
///
/// # Safety
/// `string` must be a pointer returned by `agentbrowser_evaluate` and not used
/// afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_free_string(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    // SAFETY: the pointer came from `CString::into_raw` in this crate.
    drop(unsafe { CString::from_raw(string) });
}

/// Nominate the webview CDP commands operate on. The `new_webview` callback
/// already does this; the setter covers a resumed tab.
///
/// # Safety
/// `engine` must be live and `webview` NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_set_webview(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    engine.runtime.set_webview(webview_id).is_ok()
}

/// Close the agent tab.
///
/// # Safety
/// `engine` must be live and `webview` NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_close(
    engine_pointer: *mut Engine,
    webview_pointer: *const c_char,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let Some(webview_id) = webview(engine, webview_pointer) else {
        return false;
    };
    engine.provider.close_webview(webview_id).is_ok()
}

/// Emit an event on a CDP domain registered by the embedder.
///
/// # Safety
/// `engine` must be live; the strings are NUL-terminated for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_emit_cdp_event(
    engine_pointer: *mut Engine,
    method: *const c_char,
    params_json: *const c_char,
) -> bool {
    let Some(engine) = engine(engine_pointer) else {
        return false;
    };
    let params = serde_json::from_str(&engine.callbacks.string(params_json))
        .unwrap_or_else(|_| json!({}));
    engine
        .runtime
        .emit_cdp_event(
            CdpEvent::Custom {
                method: engine.callbacks.string(method),
                params,
            },
            Duration::from_secs(1),
        )
        .is_ok()
}

/// Close and free the engine.
///
/// # Safety
/// `engine` must be a pointer returned by `agentbrowser_create` and not used
/// again afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentbrowser_destroy(engine_pointer: *mut Engine) {
    if engine_pointer.is_null() {
        return;
    }
    // SAFETY: the caller transfers ownership of a pointer from
    // `agentbrowser_create` exactly once.
    let mut engine = unsafe { Box::from_raw(engine_pointer) };
    // Stop the CDP listener first, then the automation thread. Joining the
    // automation thread drops its provider Arc; the engine's own Arc then
    // drops with the Box, which runs `UserAgent::drop` and shuts down the
    // content, net and graphics helpers.
    engine._cdp_server = None;
    engine.automation_stop.store(true, Ordering::SeqCst);
    if let Some(thread) = engine.automation_thread.take() {
        let _ = thread.join();
    }
    drop(engine);
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum UiEventJson {
    Pointer {
        phase: String,
        x: f32,
        y: f32,
        buttons: u8,
        button: Option<String>,
        modifiers: u32,
    },
    Wheel {
        x: f32,
        y: f32,
        dx: f64,
        dy: f64,
        modifiers: u32,
    },
    Key {
        phase: String,
        key: String,
        code: String,
        text: Option<String>,
        modifiers: u32,
    },
    Ime {
        text: String,
    },
    Paste {
        text: String,
    },
}

impl UiEventJson {
    fn into_ui_event(self) -> Result<UiEvent, String> {
        match self {
            UiEventJson::Pointer {
                phase,
                x,
                y,
                buttons,
                button,
                modifiers,
            } => {
                let button = match button.as_deref() {
                    Some("secondary") => MouseEventButton::Secondary,
                    Some("auxiliary") => MouseEventButton::Auxiliary,
                    _ => MouseEventButton::Main,
                };
                let event = BlitzPointerEvent {
                    id: BlitzPointerId::Mouse,
                    is_primary: true,
                    coords: pointer_coords(x, y),
                    button,
                    buttons: MouseEventButtons::from_bits_retain(buttons),
                    mods: modifiers_from_bits(modifiers),
                    details: PointerDetails::default(),
                    element: Point { x: 0.0, y: 0.0 },
                    active_pointers: Default::default(),
                };
                Ok(match phase.as_str() {
                    "down" => UiEvent::PointerDown(event),
                    "up" => UiEvent::PointerUp(event),
                    "cancel" => UiEvent::PointerCancel(event),
                    "leave" => UiEvent::PointerLeave(event),
                    _ => UiEvent::PointerMove(event),
                })
            }
            UiEventJson::Wheel {
                x,
                y,
                dx,
                dy,
                modifiers,
            } => Ok(UiEvent::Wheel(BlitzWheelEvent {
                delta: BlitzWheelDelta::Pixels(dx, dy),
                coords: pointer_coords(x, y),
                buttons: MouseEventButtons::None,
                mods: modifiers_from_bits(modifiers),
                element: Point { x: 0.0, y: 0.0 },
            })),
            UiEventJson::Key {
                phase,
                key,
                code,
                text,
                modifiers,
            } => {
                let state = if phase == "up" {
                    KeyState::Released
                } else {
                    KeyState::Pressed
                };
                let event = BlitzKeyEvent {
                    key: key_value(&key, text.as_deref()),
                    code: code.parse().unwrap_or(Code::Unidentified),
                    modifiers: modifiers_from_bits(modifiers),
                    location: Location::Standard,
                    is_auto_repeating: false,
                    is_composing: false,
                    state,
                    text: text.map(|text| text.into()),
                };
                Ok(if state == KeyState::Pressed {
                    UiEvent::KeyDown(event)
                } else {
                    UiEvent::KeyUp(event)
                })
            }
            UiEventJson::Ime { text } => Ok(UiEvent::Ime(BlitzImeEvent::Commit(text))),
            UiEventJson::Paste { text } => Ok(UiEvent::Paste(text)),
        }
    }
}
