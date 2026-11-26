import AppKit

final class SettingsWindowController: NSWindowController {
    private let adapterPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let recentField = NSTextField()
    private let cellField = NSTextField()
    private let trainingCheck = NSButton(checkboxWithTitle: "Enable trainer", target: nil, action: nil)
    private let stepsField = NSTextField()
    private let diskField = NSTextField()
    private let discardField = NSTextField()
    private var adapters: [String] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Browser Settings"
        window.center()
        self.init(window: window)
        build()
        load()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])

        stack.addArrangedSubview(label("Adapter"))
        adapterPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(adapterPopup)

        stack.addArrangedSubview(label("Model snapshot directory"))
        modelField.placeholderString = "~/Projects/Models/Qwen3.5-4B-MLX-4bit"
        modelField.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(modelField)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.addArrangedSubview(label("Recent captures"))
        recentField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        row.addArrangedSubview(recentField)
        row.addArrangedSubview(label("Cell size (points)"))
        cellField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        row.addArrangedSubview(cellField)
        stack.addArrangedSubview(row)

        trainingCheck.target = self
        trainingCheck.action = #selector(trainingToggled)
        stack.addArrangedSubview(trainingCheck)

        let budget = NSStackView()
        budget.orientation = .horizontal
        budget.spacing = 12
        budget.addArrangedSubview(label("Max steps"))
        stepsField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        budget.addArrangedSubview(stepsField)
        budget.addArrangedSubview(label("Max MB"))
        diskField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        budget.addArrangedSubview(diskField)
        budget.addArrangedSubview(label("Max discards"))
        discardField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        budget.addArrangedSubview(discardField)
        stack.addArrangedSubview(budget)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(cancel)
        stack.addArrangedSubview(buttons)

        trainingToggled()
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }

    private func load() {
        adapters = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.adapters,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }.map(\.lastPathComponent).sorted() ?? []
        adapterPopup.removeAllItems()
        adapterPopup.addItem(withTitle: "Base model")
        adapterPopup.addItems(withTitles: adapters)
        let settings = AgentService.shared.settings
        if let id = settings.adapterID, adapters.contains(id) {
            adapterPopup.selectItem(withTitle: id)
        } else {
            adapterPopup.selectItem(at: 0)
        }
        modelField.stringValue = settings.modelDirectory ?? ""
        recentField.integerValue = settings.recentCaptures
        cellField.integerValue = settings.cellSizePoints
        trainingCheck.state = settings.trainingEnabled ? .on : .off
        stepsField.integerValue = settings.maxTrainingSteps
        diskField.integerValue = settings.maxDataDirectoryMegabytes
        discardField.integerValue = settings.maxConsecutiveDiscards
        trainingToggled()
    }

    @objc private func trainingToggled() {
        let enabled = trainingCheck.state == .on
        stepsField.isEnabled = enabled
        diskField.isEnabled = enabled
        discardField.isEnabled = enabled
    }

    @objc private func save() {
        var settings = AgentService.shared.settings
        settings.adapterID = adapterPopup.indexOfSelectedItem > 0
            ? adapterPopup.titleOfSelectedItem
            : nil
        settings.modelDirectory = modelField.stringValue.isEmpty ? nil : modelField.stringValue
        settings.recentCaptures = max(1, min(8, recentField.integerValue))
        settings.cellSizePoints = max(32, min(160, cellField.integerValue))
        settings.trainingEnabled = trainingCheck.state == .on
        settings.maxTrainingSteps = max(0, stepsField.integerValue)
        settings.maxDataDirectoryMegabytes = max(128, diskField.integerValue)
        settings.maxConsecutiveDiscards = max(1, discardField.integerValue)
        AgentService.shared.settings = settings
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }
}
