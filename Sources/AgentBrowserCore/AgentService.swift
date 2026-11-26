import AgentBrowserModel
import AppKit
import Foundation

/// The app's one coordination point: it owns the engine, the capture service,
/// the model runtime, the current task and the debug entries. The UI and the
/// CDP `Agent` domain both go through it.
@MainActor
final class AgentService {
    static let shared = AgentService()

    let settingsStore = SettingsStore()
    let entries = EntryStore()
    let adapterStore = AdapterStore()
    let activity = TaskActivity()
    private lazy var settingsBox = LockedSettings(settingsStore.settings)
    private(set) var engine: EngineBridge?
    private(set) var captureService: CaptureService?
    private(set) var runtime: ModelRuntime?
    private(set) var currentLoop: AgentLoop?
    private(set) var currentRun: URL?
    private(set) var lastError: String?
    private var trainer: Trainer?

    var onCapture: ((Capture) -> Void)?
    var onEntry: ((DebugEntry) -> Void)?
    var onSteps: (([StepRecord]) -> Void)?
    var onStatus: ((TaskStatus, String) -> Void)?
    var onDebugCleared: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onTrainerUpdate: ((TrainerUpdate) -> Void)?

    private init() {
        do {
            try AppPaths.prepare()
        } catch {
            lastError = "Could not create the data directory: \(error.localizedDescription)"
        }
    }

    var settings: AgentSettings {
        get { settingsStore.settings }
        set {
            settingsStore.settings = newValue
            settingsStore.save()
            settingsBox.settings = newValue
            if newValue.trainingEnabled, runtime != nil {
                startTrainer()
            }
            onSettingsChanged?()
        }
    }

    func start() async {
        do {
            if LaunchOptions.shared.training, !settings.trainingEnabled {
                settings.trainingEnabled = true
            }
            let model = try resolveModelDirectory()
            let extensions = try resolveExtensionsDirectory()
            if settings.adapterID == nil, let active = adapterStore.activeID {
                settings.adapterID = active
            }
            let viewport = CGSize(width: 1280, height: 720)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let grid = GridDescriptor.make(viewport: viewport, cellSize: CGFloat(settings.cellSizePoints))
            let bridge = try EngineBridge(
                extensionsDirectory: extensions,
                cdpPort: LaunchOptions.shared.cdpPort ?? 0,
                viewport: viewport,
                scale: scale
            )
            let capture = CaptureService(store: bridge.layerStore, engine: bridge, grid: grid)
            bridge.screenshotProvider = { [weak capture] in capture?.screenshotPNG() }
            bridge.onRequestNextFrame = {}
            bridge.onNavigationCompleted = { [weak capture] _ in capture?.noteNavigation() }
            bridge.domainHandler = { [weak self] method, params in
                self?.handleCDP(method: method, params: params) ?? "{}"
            }
            bridge.onTitleChanged = { [weak self] title in
                self?.lastError = nil
                NotificationCenter.default.post(name: .agentTitleChanged, object: title)
            }
            self.engine = bridge
            self.captureService = capture
            let modelRuntime = ModelRuntime(
                configuration: .init(
                    modelDirectory: model,
                    maxTokens: 2_048,
                    temperature: 0.2,
                    thinking: true
                )
            )
            self.runtime = modelRuntime
            _ = bridge.start(url: "about:blank")
            Task.detached { [weak self] in
                do {
                    try await modelRuntime.prepare()
                    await MainActor.run {
                        self?.lastError = nil
                        if LaunchOptions.shared.training || (self?.settings.trainingEnabled ?? false) {
                            self?.startTrainer()
                        }
                        self?.resumeLastRunningTask()
                    }
                } catch {
                    await MainActor.run {
                        self?.lastError = error.localizedDescription
                        self?.onStatus?(.stopped, error.localizedDescription)
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            AgentLog.write("startup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tasks

    @discardableResult
    func startTask(task: String, url: String? = nil, siteLabel: String? = nil, seed: String? = nil) -> [String: Any] {
        guard let engine, let captureService, let runtime else {
            return ["error": lastError ?? "The engine is not ready."]
        }
        currentLoop?.stop(notify: false)
        let label = siteLabel ?? "manual"
        let run = AppPaths.newRunDirectory(label: label)
        currentRun = run
        let viewport = engine.viewport
        let grid = GridDescriptor.make(
            viewport: viewport,
            cellSize: CGFloat(settings.cellSizePoints)
        )
        captureService.updateViewport(viewport, grid: grid)
        let prompt = BrowserPrompt.system(
            PromptContext(
                viewportWidth: Int(viewport.width),
                viewportHeight: Int(viewport.height),
                columns: grid.columns,
                rows: grid.rows,
                recentCaptures: settings.recentCaptures,
                gridVisible: ProcessInfo.processInfo.environment["AGENT_BROWSER_GRID"] != "0"
            )
        )
        let chosenAdapter = settings.trainingEnabled
            ? adapterStore.choose(candidateProbability: settings.candidateAssignmentProbability)
            : settings.adapterID
        var record = ConversationRecord(
            task: task,
            siteLabel: label,
            seed: seed,
            adapterID: chosenAdapter,
            systemPrompt: prompt,
            grid: grid,
            viewport: viewport
        )
        record.lastURL = url ?? engine.url
        record.messages.append(StoredMessage(role: "user", content: task, step: 0))
        let conversation = ConversationStore(directory: run, record: record)
        let loop = AgentLoop(
            conversation: conversation,
            runtime: runtime,
            engine: engine,
            captureService: captureService,
            settings: settings,
            entries: entries
        )
        configure(loop)
        currentLoop = loop
        activity.isRunning = true
        entries.reset()
        onDebugCleared?()
        let systemEntry = DebugEntry(
            step: 0,
            kind: .systemPrompt,
            summary: "System prompt",
            promptText: prompt
        )
        let taskEntry = DebugEntry(step: 0, kind: .task, summary: task, output: task)
        for entry in [systemEntry, taskEntry] {
            entries.append(entry)
            onEntry?(entry)
        }
        loop.start(resume: false)
        return ["run": run.path, "task": task]
    }

    private func configure(_ loop: AgentLoop) {
        loop.onEntry = { [weak self] entry in
            Task { @MainActor in
                self?.onEntry?(entry)
                self?.emitStep(entry)
            }
        }
        loop.onCapture = { [weak self] capture in
            Task { @MainActor in self?.onCapture?(capture) }
        }
        loop.onStepsChanged = { [weak self] steps in
            Task { @MainActor in self?.onSteps?(steps) }
        }
        loop.onStatusChanged = { [weak self] status, reply in
            Task { @MainActor in
                self?.onStatus?(status, reply)
                if status == .finished || status == .stopped {
                    self?.activity.isRunning = false
                    self?.engine?.emitCDPEvent(
                        method: "Agent.taskFinished",
                        params: ["status": status.rawValue, "reply": reply]
                    )
                }
            }
        }
    }

    /// Pick up a task whose conversation says it was running when the app
    /// stopped. A tool call that was in flight gets an interrupted result so
    /// the model asks for a capture and every action runs once.
    private func resumeLastRunningTask() {
        guard currentLoop == nil, let engine, let captureService, let runtime else { return }
        let runs = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.trajectories,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for run in runs {
            guard let (store, record) = ConversationStore.load(from: run),
                  record.status == .running
            else { continue }
            var repaired = record
            if let lastAssistant = repaired.messages.lastIndex(where: {
                $0.role == "assistant" && !($0.toolCalls?.isEmpty ?? true)
            }) {
                let calls = repaired.messages[lastAssistant].toolCalls ?? []
                let hasResults = repaired.messages[(lastAssistant + 1)...].contains { $0.role == "tool" }
                if !hasResults {
                    for call in calls {
                        repaired.messages.append(
                            StoredMessage(
                                role: "tool",
                                content: "The tool call was interrupted; its effect may or may not have happened. Request a capture to see where the page stands.",
                                toolCallID: call.id,
                                toolName: call.name,
                                step: repaired.messages[lastAssistant].step
                            )
                        )
                    }
                    store.update { $0.messages = repaired.messages }
                }
            }
            captureService.updateViewport(repaired.viewport, grid: repaired.grid)
            let loop = AgentLoop(
                conversation: store,
                runtime: runtime,
                engine: engine,
                captureService: captureService,
                settings: settings,
                entries: entries
            )
            configure(loop)
            currentLoop = loop
            currentRun = run
            activity.isRunning = true
            loop.start(resume: true)
            return
        }
    }

    func sendMessage(_ text: String) {
        currentLoop?.sendPersonMessage(text)
    }

    func stopTask() {
        currentLoop?.stop()
        activity.isRunning = false
    }

    private func startTrainer() {
        guard trainer == nil, let runtime else { return }
        let trainer = Trainer(
            runtime: runtime,
            adapterStore: adapterStore,
            settings: settingsBox,
            activity: activity,
            entries: entries
        )
        trainer.onUpdate = { [weak self] update in
            AgentLog.write(
                "trainer \(update.state) step=\(update.step) loss=\(update.loss.map { String(format: "%.4f", $0) } ?? "-") elapsed=\(String(format: "%.1f", update.elapsed))s \(update.message)"
            )
            Task { @MainActor in self?.onTrainerUpdate?(update) }
        }
        trainer.start()
        self.trainer = trainer
    }

    var trainerStatus: TrainerUpdate? {
        trainer?.status()
    }

    func state() -> [String: Any] {
        let loopState = currentLoop?.state
        let record = currentLoop?.conversation.current
        return [
            "status": loopState?.status.rawValue ?? "stopped",
            "finalReply": loopState?.finalReply ?? "",
            "stepCount": loopState?.stepCount ?? 0,
            "turnCount": loopState?.turnCount ?? 0,
            "steps": (loopState?.steps ?? []).map { step in
                [
                    "index": step.index,
                    "note": step.note,
                    "actions": step.actionSummaries,
                    "results": step.resultLines,
                    "captures": step.capturePaths,
                    "duration": step.duration,
                ] as [String: Any]
            },
            "conversationPath": loopState?.conversationPath ?? "",
            "trajectoryDirectory": loopState?.trajectoryDirectory ?? "",
            "task": record?.task ?? "",
            "siteLabel": record?.siteLabel ?? "",
            "seed": record?.seed ?? "",
            "adapter": record?.adapterID ?? settings.adapterID ?? "base",
        ]
    }

    func shutdown() {
        currentLoop?.stop(notify: false)
        trainer?.stop()
        trainer = nil
        engine?.closeWebview()
        engine?.destroy()
        engine = nil
        captureService = nil
        runtime = nil
        EngineBridge.shutdown()
    }

    func clearDebugView() {
        entries.clearView()
        onDebugCleared?()
    }

    func copySelectedEntry(_ entry: DebugEntry?) -> String {
        guard let entry else { return "" }
        var lines = ["step \(entry.step) \(entry.kind.rawValue): \(entry.summary)"]
        if let prompt = entry.promptText { lines.append(prompt) }
        if let thinking = entry.thinking { lines.append("thinking:\n\(thinking)") }
        if let output = entry.output { lines.append("output:\n\(output)") }
        if let calls = entry.toolCallsJSON { lines.append("tool calls:\n\(calls)") }
        if let result = entry.resultText { lines.append("result:\n\(result)") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - CDP Agent domain

    nonisolated func handleCDP(method: String, params: String) -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                self.handleCDPOnMain(method: method, params: params)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.handleCDPOnMain(method: method, params: params)
            }
        }
    }

    @MainActor
    private func handleCDPOnMain(method: String, params: String) -> String {
        let object = JSON.object(params)
        switch method {
        case "Agent.startTask":
            let task = object["task"] as? String ?? ""
            guard !task.isEmpty else { return JSON.string(["error": "task is required"]) }
            let result = startTask(
                task: task,
                url: object["url"] as? String,
                siteLabel: object["siteLabel"] as? String,
                seed: object["seed"] as? String
            )
            return JSON.string(result)
        case "Agent.sendMessage":
            let text = object["text"] as? String ?? ""
            guard !text.isEmpty else { return JSON.string(["error": "text is required"]) }
            sendMessage(text)
            return "{}"
        case "Agent.stopTask":
            stopTask()
            return "{}"
        case "Agent.getState":
            return JSON.string(state())
        default:
            return JSON.string(["error": "unknown Agent method \(method)"])
        }
    }

    private func emitStep(_ entry: DebugEntry) {
        guard entry.kind == .toolCall || entry.kind == .toolResult
            || entry.kind == .capture || entry.kind == .personMessage
            || entry.kind == .output || entry.kind == .thinking
        else { return }
        var params: [String: Any] = [
            "step": entry.step,
            "kind": entry.kind.rawValue,
            "summary": entry.summary,
            "time": ISO8601DateFormatter().string(from: entry.time),
        ]
        if let path = entry.capturePath { params["capturePath"] = path }
        if let output = entry.output { params["output"] = output }
        if let thinking = entry.thinking { params["thinking"] = thinking }
        engine?.emitCDPEvent(method: "Agent.stepAdded", params: params)
    }

    // MARK: - Paths

    private func resolveModelDirectory() throws -> URL {
        if let path = LaunchOptions.shared.modelDirectory, !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AGENT_BROWSER_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        if let path = settings.modelDirectory, !path.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Models/Qwen3.5-4B-MLX-4bit"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../Models/Qwen3.5-4B-MLX-4bit")
                .standardizedFileURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Models/Qwen3.5-4B-MLX-4bit")
                .standardizedFileURL,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw NSError(
            domain: "agent-browser",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "No model snapshot. Set AGENT_BROWSER_MODEL to the Qwen3.5-4B-MLX-4bit directory."]
        )
    }

    private func resolveExtensionsDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AGENT_BROWSER_EXTENSIONS"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("engine"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../formal-web/target/debug"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../formal-web/target/release"),
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw NSError(
            domain: "agent-browser",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "No engine helpers. Build formal-web or set AGENT_BROWSER_EXTENSIONS."]
        )
    }
}

final class SettingsStore {
    var settings: AgentSettings

    init() {
        settings = AgentSettings.load()
    }

    func save() {
        settings.save()
    }
}

extension Notification.Name {
    static let agentTitleChanged = Notification.Name("AgentTitleChanged")
}

struct LaunchOptions {
    var cdpPort: UInt16?
    var training: Bool = false
    var startupURL: String?
    var dataDirectory: String?
    var modelDirectory: String?

    static let shared: LaunchOptions = {
        var options = LaunchOptions()
        var arguments = CommandLine.arguments.dropFirst()
        while let argument = arguments.popFirst() {
            switch argument {
            case "--cdp-port":
                options.cdpPort = arguments.popFirst().flatMap { UInt16($0) }
            case "--training":
                options.training = true
            case "--url":
                options.startupURL = arguments.popFirst()
            case "--data-dir":
                options.dataDirectory = arguments.popFirst()
            case "--model":
                options.modelDirectory = arguments.popFirst()
            default:
                break
            }
        }
        return options
    }()
}
