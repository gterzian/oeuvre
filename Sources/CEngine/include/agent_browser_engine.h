#ifndef AGENT_BROWSER_ENGINE_H
#define AGENT_BROWSER_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One layer handed to Swift. `topology_json` and `bytes` are valid only for
/// the duration of the layer callback.
typedef struct {
    const char *topology_json;
    uint32_t width;
    uint32_t height;
    uint8_t surface_kind; // 0 = clean, 1 = shared IOSurface, 2 = CPU bytes
    uint32_t surface_id;
    uint32_t surface_port; // Mach send right for the fallback lookup; Swift frees it
    uint64_t texture_id;
    const uint8_t *bytes;
    size_t byte_len;
    size_t bytes_per_row;
} ABILayer;

typedef void (*ABINavigationFn)(void *context, const char *webview, const char *text);
typedef void (*ABIWebviewFn)(void *context, const char *webview, const char *text);
typedef void (*ABIFrameFn)(void *context, const char *webview);
typedef float (*ABIScaleFn)(void *context);
typedef bool (*ABIViewportFn)(void *context, uint32_t *width, uint32_t *height,
                              float *scale, uint8_t *dark);
typedef void (*ABITextFn)(void *context, const char *text);
typedef void (*ABIHostMessageFn)(void *context, const char *webview, const char *url,
                                 const char *body);
typedef void (*ABILayersFn)(void *context, const char *webview,
                            const ABILayer *layers, size_t count, bool animating,
                            int32_t composition_kind);
typedef uint8_t *(*ABIScreenshotFn)(void *context, size_t *length);
typedef char *(*ABIDomainCallFn)(void *context, const char *method,
                                 const char *params_json);
typedef void (*ABIFreeStringFn)(char *string);
typedef void (*ABIFreeBytesFn)(uint8_t *bytes, size_t length);
typedef void (*ABILogFn)(void *context, int32_t level, const char *message);

typedef struct {
    void *context;
    ABINavigationFn navigation_requested;
    ABINavigationFn navigation_completed;
    ABIWebviewFn new_webview;
    ABIFrameFn request_next_frame;
    ABIScaleFn viewport_scale_factor;
    ABIViewportFn window_viewport;
    ABITextFn clipboard_set_text;
    ABIHostMessageFn host_message;
    ABIWebviewFn title_changed;
    ABILayersFn layers;
    ABIScreenshotFn screenshot;
    ABIDomainCallFn domain_call;
    ABIFreeStringFn free_string;
    ABIFreeBytesFn free_bytes;
    ABILogFn log;
} ABICallbacks;

/// Create the engine. `cdp_port` is zero when the endpoint is off. The
/// webview arrives through `new_webview`; nothing here waits for it.
void *agentbrowser_create(const char *extensions_directory, uint16_t cdp_port,
                          ABICallbacks callbacks);

/// Ask the engine to start the first webview. The webview arrives through
/// `new_webview`.
bool agentbrowser_start(void *engine, const char *url);

/// Set the default viewport before the first webview exists.
bool agentbrowser_set_default_viewport(void *engine, uint32_t width,
                                       uint32_t height, float scale);

/// Update the traversable viewport in physical pixels and scale.
bool agentbrowser_set_viewport(void *engine, const char *webview,
                               uint32_t width, uint32_t height, float scale);

/// Navigate the agent tab.
bool agentbrowser_navigate(void *engine, const char *webview, const char *url);

/// Raise one rendering opportunity. A non-positive deadline means none.
bool agentbrowser_frame_needed(void *engine, const char *webview,
                               int64_t display_deadline_ms);

/// Send one UI event as JSON.
bool agentbrowser_send_ui_event(void *engine, const char *webview,
                                const char *json);

/// Evaluate a script. Returns a Rust-owned JSON string; free it with
/// `agentbrowser_free_string`.
char *agentbrowser_evaluate(void *engine, const char *webview,
                            const char *source, uint64_t timeout_ms);

/// Nominate the webview CDP commands operate on.
bool agentbrowser_set_webview(void *engine, const char *webview);

/// Close the agent tab.
bool agentbrowser_close(void *engine, const char *webview);

/// Free a string returned by `agentbrowser_evaluate`.
void agentbrowser_free_string(char *string);

/// Emit an event on a registered CDP domain.
bool agentbrowser_emit_cdp_event(void *engine, const char *method,
                                 const char *params_json);

/// Close and free the engine.
void agentbrowser_destroy(void *engine);

#ifdef __cplusplus
}
#endif

#endif
