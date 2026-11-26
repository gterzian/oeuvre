import AppKit

/// The app's window is deliberately small in scope: the last frame the agent
/// received, and the session history below it. The coding agent sets tasks and
/// reads the evaluation; the person only needs to watch the browser session.
final class MainWindowController: NSWindowController {
    private let tabView = AgentTabView()
    private let debugPanel = DebugPanelView()
    private let divider = NSView()
    private var debugHeight: CGFloat = 320
    private var debugVisible = true
    private var debugHeightConstraint: NSLayoutConstraint?
    private var dividerHeightConstraint: NSLayoutConstraint?
    private var panStart: CGFloat = 0
    private var panStartY: CGFloat = 0
    /// The frame the window should keep while its content loads. AppKit fits
    /// the window to the new intrinsic sizes of the history toolbar and the
    /// capture image on the first layout; restoring this frame keeps the
    /// window the size the person opened it at.
    private var pinnedFrame: NSRect?
    private var restoringFrame = false

    convenience init() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Leave a margin on every side of the usable screen. A window that
        // touches the dock or the menu bar hides the panels the person needs.
        let margin: CGFloat = 24
        let width = min(1_060, visible.width - margin * 2)
        let height = min(680, visible.height - margin * 2)
        let window = NSWindow(
            contentRect: NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Browser"
        window.minSize = NSSize(width: min(860, width), height: min(560, height))
        self.init(window: window)
        pinnedFrame = window.frame
        build()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillStartLiveResize(_:)),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        if ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil {
            AgentLog.write("window initial frame=\(window.frame) visible=\(visible)")
        }
        wire()
        refresh()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        debugPanel.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor

        content.addSubview(tabView)
        content.addSubview(debugPanel)
        content.addSubview(divider)

        debugHeightConstraint = debugPanel.heightAnchor.constraint(equalToConstant: debugHeight)
        dividerHeightConstraint = divider.heightAnchor.constraint(equalToConstant: 6)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: content.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: divider.topAnchor),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: debugPanel.topAnchor),
            dividerHeightConstraint!,

            debugPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            debugPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            debugPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            debugHeightConstraint!,
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(dragDivider(_:)))
        divider.addGestureRecognizer(pan)
    }

    private func wire() {
        let service = AgentService.shared
        service.onCapture = { [weak self] capture in
            self?.tabView.show(capture)
        }
        service.onEntry = { [weak self] entry in
            self?.debugPanel.append(entry)
        }
        service.onDebugCleared = { [weak self] in
            self?.debugPanel.setEntries([])
        }
        service.onSettingsChanged = { [weak self] in
            self?.debugPanel.setAdapter(AgentService.shared.settings.adapterID)
        }
        service.onTrainerUpdate = { _ in }
        debugPanel.onClear = {
            AgentService.shared.clearDebugView()
        }
        debugPanel.onCopy = { entry in
            let text = AgentService.shared.copySelectedEntry(entry)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        debugPanel.onReveal = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func refresh() {
        let service = AgentService.shared
        debugPanel.setAdapter(service.settings.adapterID)
        debugPanel.setEntries(service.entries.all)
        showLastFrame()
    }

    /// Show the newest frame the model received: the live capture if there is
    /// one, otherwise the last capture stored in the current conversation.
    private func showLastFrame() {
        let service = AgentService.shared
        if let capture = service.captureService?.recentCaptures.last {
            tabView.show(capture)
            return
        }
        if let record = service.currentLoop?.conversation.current,
           let path = record.messages.reversed().first(where: { !$0.imagePaths.isEmpty })?.imagePaths.last,
           let image = ImageSupport.image(at: URL(fileURLWithPath: path))
        {
            tabView.show(
                Capture(
                    image: image,
                    png: Data(),
                    grid: record.grid,
                    viewport: record.viewport,
                    step: record.stepCount,
                    caption: "Last frame sent to the agent"
                )
            )
            return
        }
        tabView.showPlaceholder("The agent tab appears here.")
    }

    @objc private func dragDivider(_ gesture: NSPanGestureRecognizer) {
        let location = gesture.location(in: window?.contentView)
        switch gesture.state {
        case .began:
            panStart = debugHeight
            panStartY = location.y
        case .changed:
            let delta = location.y - panStartY
            debugHeight = max(100, min(600, panStart + delta))
            debugHeightConstraint?.constant = debugHeight
            window?.contentView?.layoutSubtreeIfNeeded()
        default:
            break
        }
    }

    func toggleDebugPanel() {
        debugVisible.toggle()
        debugPanel.isHidden = !debugVisible
        divider.isHidden = !debugVisible
        debugHeightConstraint?.constant = debugVisible ? debugHeight : 0
        dividerHeightConstraint?.constant = debugVisible ? 6 : 0
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Window size

    /// Automatic content fitting is not a live resize, so it does not mean the
    /// person chose a new size. Restore the pinned frame until the person
    /// starts dragging an edge; from then on the window is theirs.
    @objc private func windowWillStartLiveResize(_ notification: Notification) {
        pinnedFrame = nil
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard !restoringFrame, var pinned = pinnedFrame, let window else { return }
        // A content-fitting resize also moves the window. Only a move at the
        // pinned size is the person placing the window.
        let size = window.frame.size
        guard abs(size.width - pinned.width) < 0.5,
              abs(size.height - pinned.height) < 0.5
        else { return }
        pinned.origin = window.frame.origin
        pinnedFrame = pinned
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard !restoringFrame, let pinned = pinnedFrame, let window else { return }
        let size = window.frame.size
        guard abs(size.width - pinned.width) > 0.5 || abs(size.height - pinned.height) > 0.5
        else { return }
        if ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil {
            AgentLog.write("window grew to \(size); restoring to \(pinned.size)")
        }
        restoringFrame = true
        var frame = window.frame
        frame.origin = pinned.origin
        frame.size = pinned.size
        window.setFrame(frame, display: true)
        DispatchQueue.main.async { [weak self] in self?.restoringFrame = false }
    }
}
