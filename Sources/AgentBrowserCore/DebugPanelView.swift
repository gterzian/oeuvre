import AppKit

/// The browser agent's session history. This is the part the person cannot
/// see anywhere else: every prompt, thought, reply, tool call, tool result and
/// capture the loop records, newest last.
final class DebugPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onReveal: ((URL) -> Void)?
    var onClear: (() -> Void)?
    var onCopy: ((DebugEntry?) -> Void)?

    private let searchField = NSSearchField()
    private let follow = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let adapterLabel = NSTextField(labelWithString: "base")
    private let table = NSTableView()
    private let tabs = NSTabView()
    private let promptText = NSTextView()
    private let thinkingText = NSTextView()
    private let outputText = NSTextView()
    private let timingText = NSTextView()
    private var entries: [DebugEntry] = []
    private var filtered: [DebugEntry] = []
    private var filters: [EntryKind: NSButton] = [:]
    private var selectedEntry: DebugEntry?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) { nil }

    func setEntries(_ entries: [DebugEntry]) {
        self.entries = entries
        if ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil {
            AgentLog.write("history set \(entries.count) entries")
        }
        applyFilters()
    }

    func append(_ entry: DebugEntry) {
        if ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil {
            AgentLog.write("history append \(entry.kind.rawValue): \(entry.summary)")
        }
        entries.append(entry)
        applyFilters()
        if follow.state == .on, selectedEntry == nil {
            selectLast()
        }
    }

    func setAdapter(_ id: String?) {
        adapterLabel.stringValue = id.map { "adapter: \($0)" } ?? "adapter: base"
    }

    private func build() {
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        searchField.controlSize = .small
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        follow.state = .on
        follow.controlSize = .small
        for kind in EntryKind.allCases {
            let button = NSButton(checkboxWithTitle: kind.rawValue, target: self, action: #selector(toggleFilter(_:)))
            button.controlSize = .mini
            button.state = .on
            button.tag = EntryKind.allCases.firstIndex(of: kind) ?? 0
            filters[kind] = button
            toolbar.addArrangedSubview(button)
        }
        clearButton.target = self
        clearButton.action = #selector(clear)
        copyButton.target = self
        copyButton.action = #selector(copyEntry)
        revealButton.target = self
        revealButton.action = #selector(reveal)
        for button in [clearButton, copyButton, revealButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
        }
        adapterLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        adapterLabel.textColor = .secondaryLabelColor
        toolbar.addArrangedSubview(searchField)
        toolbar.addArrangedSubview(follow)
        toolbar.addArrangedSubview(clearButton)
        toolbar.addArrangedSubview(copyButton)
        toolbar.addArrangedSubview(revealButton)
        toolbar.addArrangedSubview(adapterLabel)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step")))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time")))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind")))
        let summary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        summary.width = 420
        table.addTableColumn(summary)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration")))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tokens")))
        table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        tableScroll.documentView = table
        split.addArrangedSubview(tableScroll)

        for (title, text) in [
            ("Prompt", promptText),
            ("Thinking", thinkingText),
            ("Output", outputText),
            ("Timing", timingText),
        ] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            text.isEditable = false
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            text.textContainerInset = NSSize(width: 4, height: 4)
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.documentView = text
            item.view = scroll
            tabs.addTabViewItem(item)
        }
        split.addArrangedSubview(tabs)
        split.setPosition(560, ofDividerAt: 0)
    }

    @objc private func toggleFilter(_ sender: NSButton) {
        applyFilters()
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilters()
    }

    private func applyFilters() {
        let text = searchField.stringValue.lowercased()
        filtered = entries.filter { entry in
            if let button = filters[entry.kind], button.state != .on { return false }
            if text.isEmpty { return true }
            return entry.summary.lowercased().contains(text)
                || entry.kind.rawValue.contains(text)
                || (entry.output ?? "").lowercased().contains(text)
        }
        table.reloadData()
        if follow.state == .on, selectedEntry == nil {
            selectLast()
        }
    }

    private func selectLast() {
        guard !filtered.isEmpty else { return }
        let row = filtered.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clear() {
        entries.removeAll()
        filtered.removeAll()
        selectedEntry = nil
        table.reloadData()
        onClear?()
    }

    @objc private func copyEntry() {
        onCopy?(selectedEntry)
    }

    @objc private func reveal() {
        guard let selected = selectedEntry else { return }
        if let path = selected.capturePath {
            onReveal?(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let identifier = NSUserInterfaceItemIdentifier("debug-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue {
        case "step": cell.stringValue = "\(entry.step)"
        case "time":
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            cell.stringValue = formatter.string(from: entry.time)
        case "kind":
            cell.stringValue = entry.kind.rawValue
            cell.textColor = color(for: entry.kind)
        case "duration":
            cell.stringValue = entry.duration.map { String(format: "%.2fs", $0) } ?? ""
        case "tokens":
            if let prompt = entry.promptTokens, let reply = entry.replyTokens {
                cell.stringValue = "\(prompt)/\(reply)"
            } else {
                cell.stringValue = ""
            }
        default:
            cell.stringValue = entry.summary
            cell.textColor = .labelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let entry = filtered[row]
        selectedEntry = entry
        promptText.string = entry.promptText ?? entry.summary
        thinkingText.string = entry.thinking ?? ""
        var output = entry.output ?? ""
        if let calls = entry.toolCallsJSON, !calls.isEmpty {
            output += "\n\nTool calls:\n\(calls)"
        }
        if let result = entry.resultText {
            output += "\n\nResult:\n\(result)"
        }
        outputText.string = output
        var timing: [String] = []
        if let value = entry.timeToFirstToken { timing.append("time to first token: \(String(format: "%.2fs", value))") }
        if let value = entry.generationTime { timing.append("generation: \(String(format: "%.2fs", value))") }
        if let prompt = entry.promptTokens { timing.append("prompt tokens: \(prompt)") }
        if let reply = entry.replyTokens { timing.append("reply tokens: \(reply)") }
        if let value = entry.generationTime, value > 0, let reply = entry.replyTokens {
            timing.append("tokens per second: \(String(format: "%.1f", Double(reply) / value))")
        }
        timingText.string = timing.joined(separator: "\n")
    }

    private func color(for kind: EntryKind) -> NSColor {
        switch kind {
        case .request: .systemBlue
        case .thinking: .systemPurple
        case .output: .systemGreen
        case .toolCall: .systemOrange
        case .toolResult: .systemTeal
        case .capture: .systemPink
        case .personMessage: .systemYellow
        default: .secondaryLabelColor
        }
    }
}
