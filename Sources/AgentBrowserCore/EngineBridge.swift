import AppKit
import CEngine
import CoreGraphics
import Darwin
import Foundation

/// The Swift half of the binding crate. The Rust side owns the
/// `WebviewProvider`; this class turns its C callbacks into Swift state and
/// forwards actions back through the C entry points.
final class EngineBridge: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()
    private let store: LayerStore
    private var viewportPoints: CGSize
    private var scale: CGFloat
    private var currentURL: String = ""
    private var currentTitle: String = ""
    private var webviewID: String?
    private var destroyed = false

    /// Raised when the user agent reports a queued update without a rendering
    /// opportunity. The capture service uses it to know when a `wait` until
    /// `change` may have something to show.
    var onRequestNextFrame: (() -> Void)?
    var onNavigationCompleted: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onNewWebview: (() -> Void)?

    /// The CDP `Agent` domain handler. It receives `(method, paramsJSON)` and
    /// returns a JSON object.
    var domainHandler: ((String, String) -> String)?
    /// A PNG of the current composition without the grid, for
    /// `Page.captureScreenshot`.
    var screenshotProvider: (() -> Data?)?

    init(extensionsDirectory: URL, cdpPort: UInt16, viewport: CGSize, scale: CGFloat) throws {
        self.store = LayerStore()
        self.viewportPoints = viewport
        self.scale = max(1, scale)
        store.setViewport(viewport)

        let callbacks = EngineBridge.makeCallbacks()
        let path = extensionsDirectory.path
        let created = path.withCString { directory in
            agentbrowser_create(directory, cdpPort, callbacks)
        }
        guard let created else {
            throw BridgeError.engineStartFailed
        }
        self.handle = created
        EngineBridge.register(self)
        _ = agentbrowser_set_default_viewport(
            created,
            UInt32(max(1, viewport.width * scale)),
            UInt32(max(1, viewport.height * scale)),
            Float(scale)
        )
    }

    deinit {
        destroy()
    }

    /// Destroy the Rust engine, which drops the user agent and shuts down its
    /// helper processes. Idempotent: `deinit` and the app's termination hook
    /// may both reach it.
    func destroy() {
        lock.lock()
        guard !destroyed else {
            lock.unlock()
            return
        }
        destroyed = true
        lock.unlock()
        agentbrowser_destroy(handle)
    }

    enum BridgeError: Error, LocalizedError {
        case engineStartFailed
        case noEngine

        var errorDescription: String? {
            switch self {
            case .engineStartFailed: "The engine could not start."
            case .noEngine: "The engine is not available."
            }
        }
    }

    var layerStore: LayerStore { store }
    var viewport: CGSize { lock.withLock { viewportPoints } }

    var url: String {
        lock.withLock { currentURL }
    }

    var title: String {
        lock.withLock { currentTitle }
    }

    var isReady: Bool {
        lock.withLock { webviewID != nil }
    }

    var webview: String? {
        lock.withLock { webviewID }
    }

    @discardableResult
    func start(url: String) -> Bool {
        url.withCString { agentbrowser_start(handle, $0) }
    }

    @discardableResult
    func navigate(to url: String) -> Bool {
        guard let webview = webview else { return false }
        return webview.withCString { webviewPointer in
            url.withCString { urlPointer in
                agentbrowser_navigate(handle, webviewPointer, urlPointer)
            }
        }
    }

    func setViewport(points: CGSize, scale: CGFloat) {
        lock.lock()
        viewportPoints = points
        self.scale = max(1, scale)
        let webview = webviewID
        lock.unlock()
        store.setViewport(points)
        guard let webview else { return }
        webview.withCString { webviewPointer in
            _ = agentbrowser_set_viewport(
                handle,
                webviewPointer,
                UInt32(max(1, points.width * scale)),
                UInt32(max(1, points.height * scale)),
                Float(scale)
            )
        }
    }

    @discardableResult
    func frameNeeded(displayDeadlineMilliseconds: Int64 = 0) -> Bool {
        guard let webview = webview else { return false }
        return webview.withCString { webviewPointer in
            agentbrowser_frame_needed(handle, webviewPointer, displayDeadlineMilliseconds)
        }
    }

    @discardableResult
    func send(_ eventJSON: String) -> Bool {
        guard let webview = webview else { return false }
        return webview.withCString { webviewPointer in
            eventJSON.withCString { eventPointer in
                agentbrowser_send_ui_event(handle, webviewPointer, eventPointer)
            }
        }
    }

    func evaluate(_ script: String, timeout: TimeInterval = 5) -> Any? {
        guard let webview = webview else { return nil }
        return webview.withCString { webviewPointer in
            script.withCString { source in
                let pointer = agentbrowser_evaluate(
                    handle,
                    webviewPointer,
                    source,
                    UInt64(max(1, timeout * 1000))
                )
                guard let pointer else { return nil }
                defer { agentbrowser_free_string(pointer) }
                let text = String(cString: pointer)
                guard let data = text.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }
        }
    }

    @discardableResult
    func closeWebview() -> Bool {
        guard let webview = webview else { return false }
        return webview.withCString { agentbrowser_close(handle, $0) }
    }

    /// Wait until the `new_webview` callback has named the tab. The engine
    /// start is asynchronous, so the loop's first capture waits here instead
    /// of blocking the Rust side.
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isReady
    }

    func emitCDPEvent(method: String, params: [String: Any]) {
        let paramsText = JSON.string(params)
        method.withCString { methodPointer in
            paramsText.withCString { paramsPointer in
                _ = agentbrowser_emit_cdp_event(handle, methodPointer, paramsPointer)
            }
        }
    }

    // MARK: - Callback registry

    /// The C callbacks carry a raw context pointer. There is one engine per
    /// app, so a small registry keeps the callback functions free of captures
    /// while still reaching the current bridge.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var bridge: EngineBridge?

    private static func register(_ bridge: EngineBridge) {
        registryLock.withLock { Self.bridge = bridge }
    }

    fileprivate static var current: EngineBridge? {
        registryLock.withLock { bridge }
    }

    static func shutdown() {
        let instance = registryLock.withLock { () -> EngineBridge? in
            let current = bridge
            bridge = nil
            return current
        }
        instance?.destroy()
    }

    private static func makeCallbacks() -> ABICallbacks {
        ABICallbacks(
            context: nil,
            navigation_requested: engineNavigationRequested,
            navigation_completed: engineNavigationCompleted,
            new_webview: engineNewWebview,
            request_next_frame: engineRequestNextFrame,
            viewport_scale_factor: engineScaleFactor,
            window_viewport: engineWindowViewport,
            clipboard_set_text: engineClipboardText,
            host_message: engineHostMessage,
            title_changed: engineTitleChanged,
            layers: engineLayers,
            screenshot: engineScreenshot,
            domain_call: engineDomainCall,
            free_string: engineFreeString,
            free_bytes: engineFreeBytes,
            log: engineLog
        )
    }

    fileprivate func noteRequestNextFrame() {
        store.noteRequestNextFrame()
        onRequestNextFrame?()
    }

    fileprivate func applyLayers(
        _ incoming: [LayerSnapshot],
        animating: Bool,
        compositionKind: Int
    ) {
        store.apply(incoming, compositionKind: compositionKind)
    }

    fileprivate func setURL(_ url: String) {
        lock.lock()
        currentURL = url
        lock.unlock()
        onNavigationCompleted?(url)
    }

    fileprivate func setWebview(_ webview: String) {
        lock.lock()
        webviewID = webview
        lock.unlock()
        onNewWebview?()
    }

    fileprivate func setTitle(_ title: String) {
        lock.lock()
        currentTitle = title
        lock.unlock()
        onTitleChanged?(title)
    }

    fileprivate func readViewport() -> (UInt32, UInt32, Float, UInt8)? {
        lock.lock()
        defer { lock.unlock() }
        return (
            UInt32(max(1, viewportPoints.width * scale)),
            UInt32(max(1, viewportPoints.height * scale)),
            Float(scale),
            0
        )
    }

    fileprivate func callDomain(method: String, params: String) -> String {
        domainHandler?(method, params) ?? "{}"
    }

    fileprivate func screenshotPNG() -> Data? {
        screenshotProvider?()
    }
}

/// Opt-in layer tracing. Set `AGENT_BROWSER_TRACE_LAYERS=1` to see every
/// composition the engine delivers in the app log.
private let traceLayers = ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil

private func string(from pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

private func bridge() -> EngineBridge? { EngineBridge.current }

private func engineNavigationRequested(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ text: UnsafePointer<CChar>?
) {}

private func engineNavigationCompleted(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ text: UnsafePointer<CChar>?
) {
    bridge()?.setURL(string(from: text))
}

private func engineNewWebview(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ text: UnsafePointer<CChar>?
) {
    bridge()?.setWebview(string(from: webview))
}

private func engineRequestNextFrame(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?
) {
    bridge()?.noteRequestNextFrame()
}

private func engineScaleFactor(_ context: UnsafeMutableRawPointer?) -> Float {
    guard let viewport = bridge()?.readViewport() else { return 1 }
    return viewport.2
}

private func engineWindowViewport(
    _ context: UnsafeMutableRawPointer?,
    _ width: UnsafeMutablePointer<UInt32>?,
    _ height: UnsafeMutablePointer<UInt32>?,
    _ scale: UnsafeMutablePointer<Float>?,
    _ dark: UnsafeMutablePointer<UInt8>?
) -> Bool {
    guard let viewport = bridge()?.readViewport() else { return false }
    width?.pointee = viewport.0
    height?.pointee = viewport.1
    scale?.pointee = viewport.2
    dark?.pointee = viewport.3
    return true
}

private func engineClipboardText(
    _ context: UnsafeMutableRawPointer?,
    _ text: UnsafePointer<CChar>?
) {
    let value = string(from: text)
    DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private func engineHostMessage(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ url: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?
) {}

private func engineTitleChanged(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ text: UnsafePointer<CChar>?
) {
    bridge()?.setTitle(string(from: text))
}

private func engineLayers(
    _ context: UnsafeMutableRawPointer?,
    _ webview: UnsafePointer<CChar>?,
    _ layerPointer: UnsafePointer<ABILayer>?,
    _ count: Int,
    _ animating: Bool,
    _ compositionKind: Int32
) {
    guard let layerPointer, count > 0 else {
        if traceLayers { AgentLog.write("layers webview=\(string(from: webview)) count=0 animating=\(animating) kind=\(compositionKind)") }
        return
    }
    let buffer = UnsafeBufferPointer(start: layerPointer, count: count)
    var layers: [LayerSnapshot] = []
    layers.reserveCapacity(count)
    var trace: [String] = []
    for layer in buffer {
        guard let topologyPointer = layer.topology_json else { continue }
        let topologyText = String(cString: topologyPointer)
        guard let topologyData = topologyText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: topologyData) as? [String: Any]
        else { continue }
        let id = object["layer_id"] as? String ?? UUID().uuidString
        let parent = object["parent"] as? String
        let transformValues = object["transform"] as? [NSNumber] ?? [1, 0, 0, 1, 0, 0]
        let transform = CGAffineTransform(
            a: CGFloat(truncating: transformValues[0]),
            b: CGFloat(truncating: transformValues[1]),
            c: CGFloat(truncating: transformValues[2]),
            d: CGFloat(truncating: transformValues[3]),
            tx: CGFloat(truncating: transformValues[4]),
            ty: CGFloat(truncating: transformValues[5])
        )
        let clipValues = object["clip_bounds"] as? [NSNumber] ?? [0, 0, 0, 0]
        let clip = CGRect(
            x: CGFloat(truncating: clipValues[0]),
            y: CGFloat(truncating: clipValues[1]),
            width: max(0, CGFloat(truncating: clipValues[2]) - CGFloat(truncating: clipValues[0])),
            height: max(0, CGFloat(truncating: clipValues[3]) - CGFloat(truncating: clipValues[1]))
        )
        let zOrder = object["z_order"] as? [NSNumber] ?? [0, 0]
        let width = Int(layer.width)
        let height = Int(layer.height)
        var image: CGImage?
        switch layer.surface_kind {
        case 1:
            image = ImageSupport.imageFromIOSurface(
                id: layer.surface_id,
                port: layer.surface_port,
                width: width,
                height: height
            )
        case 2:
            if let bytes = layer.bytes, layer.byte_len > 0 {
                let data = Data(bytes: bytes, count: layer.byte_len)
                image = ImageSupport.makeImage(
                    data: data,
                    width: width,
                    height: height,
                    bytesPerRow: Int(layer.bytes_per_row)
                )
            }
        default:
            break
        }
        layers.append(
            LayerSnapshot(
                id: id,
                parent: parent,
                transform: transform,
                clipBounds: clip,
                cornerRadius: CGFloat((object["corner_radius"] as? NSNumber)?.doubleValue ?? 0),
                zIndex: Int(truncating: zOrder[0]),
                paintOrder: UInt32(truncating: zOrder[1]),
                width: width,
                height: height,
                image: image
            )
        )
        if traceLayers {
            trace.append(
                "\(id) parent=\(parent ?? "root") \(width)x\(height) kind=\(layer.surface_kind) \(image == nil ? "no-image" : "image")"
            )
        }
    }
    if traceLayers {
        AgentLog.write(
            "layers webview=\(string(from: webview)) count=\(layers.count) animating=\(animating) kind=\(compositionKind) [\(trace.joined(separator: "; "))]"
        )
    }
    bridge()?.applyLayers(layers, animating: animating, compositionKind: Int(compositionKind))
}

private func engineScreenshot(
    _ context: UnsafeMutableRawPointer?,
    _ length: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>? {
    guard let data = bridge()?.screenshotPNG(), !data.isEmpty else { return nil }
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: pointer, count: data.count)
    length?.pointee = data.count
    return pointer
}

private func engineDomainCall(
    _ context: UnsafeMutableRawPointer?,
    _ method: UnsafePointer<CChar>?,
    _ params: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let response = bridge()?.callDomain(method: string(from: method), params: string(from: params)) ?? "{}"
    return strdup(response)
}

private func engineFreeString(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

private func engineFreeBytes(_ pointer: UnsafeMutablePointer<UInt8>?, _ length: Int) {
    free(pointer)
}

private func engineLog(
    _ context: UnsafeMutableRawPointer?,
    _ level: Int32,
    _ message: UnsafePointer<CChar>?
) {
    AgentLog.write(string(from: message))
}
