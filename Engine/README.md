# Engine binding

The Rust crate that owns `WebviewProvider`, implements formal-web's `Embedder`
trait by forwarding callbacks into Swift, runs the CDP server, and exposes a C
ABI in `Sources/CEngine/include/agent_browser_engine.h`.

The API is asynchronous. `agentbrowser_start` asks the engine to start and
returns; `new_webview` names the tab, `navigation_completed` names the URL and
`layers` delivers pixels. Swift stores the webview key and passes it back to
every action entry point. The automation controller and host are owned by one
dedicated automation thread; commands reach it over a channel, and navigation
callbacks arrive as commands too. Do not add a blocking wait or a shared
mutable struct to this crate.

The crate depends on the `webview`, `automation` and `ipc_messages` packages of
the local formal-web clone. The app links the release static library; the
helpers are copied into the bundle by `scripts/build-app.sh`.
