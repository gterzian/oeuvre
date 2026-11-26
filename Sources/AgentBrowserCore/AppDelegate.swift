import AppKit
import Darwin

public enum AgentBrowserApplication {
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var settingsController: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        installMenu()
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await AgentService.shared.start()
            controller.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentService.shared.shutdown()
    }

    /// `stop-app.sh` and the test skill terminate the app with SIGTERM. AppKit
    /// does not run `applicationWillTerminate` for that signal, so route both
    /// signals through the same shutdown path; otherwise the formal-web
    /// helpers outlive the app.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    AgentService.shared.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
    }

    @objc func toggleDebugPanel(_ sender: Any?) {
        windowController?.toggleDebugPanel()
    }

    private func installMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Agent Browser",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Agent Browser",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggle = NSMenuItem(
            title: "Debug Panel",
            action: #selector(toggleDebugPanel(_:)),
            keyEquivalent: "d"
        )
        toggle.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggle)
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        NSApp.mainMenu = menu
    }
}
