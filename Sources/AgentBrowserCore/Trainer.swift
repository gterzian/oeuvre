import AgentBrowserModel
import Foundation
import MLXLMCommon

final class LockedSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentSettings

    init(_ value: AgentSettings) { self.value = value }

    var settings: AgentSettings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class TaskActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool {
        get { lock.withLock { running } }
        set { lock.withLock { running = newValue } }
    }
}

struct TrainerUpdate: Sendable {
    var state: String
    var step: Int
    var loss: Float?
    var adapter: String?
    var message: String
    /// Seconds spent in the current training session. The first step's value
    /// is the cost of one example, which is what estimates a longer session.
    var elapsed: TimeInterval
}

/// Watches the trajectories directory and turns rated runs into examples. A
/// session starts when enough new examples exist, trains while no task runs,
/// checkpoints as it goes, and leaves its last checkpoint as a candidate
/// adapter. The trainer yields at the next step boundary when a task starts.
final class Trainer: @unchecked Sendable {
    private let runtime: ModelRuntime
    private let adapterStore: AdapterStore
    private let settings: LockedSettings
    private let activity: TaskActivity
    private let entries: EntryStore
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var running = false
    private var latestStep = 0
    private var latestLoss: Float?
    private var latestAdapter: String?
    private var latestState = "waiting"
    private var latestMessage = ""
    private var sessionStartedAt: Date?

    var onUpdate: ((TrainerUpdate) -> Void)?

    init(
        runtime: ModelRuntime,
        adapterStore: AdapterStore,
        settings: LockedSettings,
        activity: TaskActivity,
        entries: EntryStore
    ) {
        self.runtime = runtime
        self.adapterStore = adapterStore
        self.settings = settings
        self.activity = activity
        self.entries = entries
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loop()
        }
        self.task = task
        lock.unlock()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func status() -> TrainerUpdate {
        lock.lock()
        defer { lock.unlock() }
        return TrainerUpdate(
            state: latestState,
            step: latestStep,
            loss: latestLoss,
            adapter: latestAdapter,
            message: latestMessage,
            elapsed: sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
    }

    private func loop() async {
        while !Task.isCancelled {
            let settings = self.settings.settings
            if !settings.trainingEnabled {
                set(state: "off", message: "Trainer is off in settings.")
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            if activity.isRunning {
                set(state: "paused", message: "Paused while an agent task runs.")
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if let reason = budgetReason(settings) {
                set(state: "stopped", message: reason)
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            let examples = collectExamples(settings)
            if examples.count < settings.trainingSessionExamples {
                set(state: "waiting", message: "\(examples.count)/\(settings.trainingSessionExamples) new examples.")
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            await runSession(examples: examples, settings: settings)
        }
    }

    private func runSession(examples: [TrainingExample], settings: AgentSettings) async {
        let id = "candidate-\(Int(Date().timeIntervalSince1970))"
        let parent = adapterStore.activeID
        let directory = AppPaths.adapters.appendingPathComponent(id, isDirectory: true)
        sessionStartedAt = Date()
        set(state: "training", message: "Training \(examples.count) examples from \(parent ?? "base").")
        let manifest = AdapterManifest(
            id: id,
            baseModel: "Qwen3.5-4B-MLX-4bit",
            parentAdapter: parent,
            experienceHash: hash(of: examples),
            hyperparameters: [
                "rank": "8",
                "scale": "10",
                "learning_rate": "1e-5",
                "batch_size": "\(settings.trainingBatchSize)",
            ],
            systemPrompt: examples.first?.systemPrompt ?? "",
            gridColumns: examples.first?.gridColumns ?? 0,
            gridRows: examples.first?.gridRows ?? 0,
            viewportWidth: examples.first?.viewportWidth ?? 0,
            viewportHeight: examples.first?.viewportHeight ?? 0,
            recentCaptures: settings.recentCaptures,
            createdAt: Date(),
            status: "training"
        )
        adapterStore.write(manifest)
        do {
            try await runtime.train(
                examples: examples,
                adapterDirectory: directory,
                parentAdapterDirectory: parent.flatMap { adapterStore.directory(for: $0) },
                configuration: TrainingConfiguration(
                    checkpointEvery: settings.checkpointEverySteps
                ),
                shouldStop: { [activity] in activity.isRunning },
                progress: { [weak self] update in
                    self?.set(
                        state: "training",
                        step: update.step,
                        loss: update.loss,
                        adapter: id,
                        message: update.checkpoint.map { "checkpoint \($0.lastPathComponent)" } ?? "training"
                    )
                }
            )
            if activity.isRunning {
                set(state: "paused", adapter: id, message: "Checkpoint saved; resumes when idle.")
                return
            }
            adapterStore.addSteps(latestStep)
            adapterStore.promoteCandidate(id: id)
            var finished = manifest
            finished.status = "candidate"
            adapterStore.write(finished)
            set(state: "candidate", adapter: id, message: "Candidate adapter ready for evaluation.")
        } catch {
            set(state: "stopped", message: "Training failed: \(error.localizedDescription)")
        }
    }

    private func collectExamples(_ settings: AgentSettings) -> [TrainingExample] {
        let experienceURL = AppPaths.adapters.appendingPathComponent("experience.json")
        var processed = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: experienceURL))) ?? []
        let processedSet = Set(processed)
        let runs = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.trajectories,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        var examples: [TrainingExample] = []
        for run in runs {
            guard !processedSet.contains(run.path) else { continue }
            let ratingURL = run.appendingPathComponent("rating.json")
            guard let ratingData = try? Data(contentsOf: ratingURL),
                  let rating = try? JSONSerialization.jsonObject(with: ratingData) as? [String: Any],
                  let score = (rating["score"] as? NSNumber)?.doubleValue
            else { continue }
            processed.append(run.path)
            if let (_, record) = ConversationStore.load(from: run) {
                adapterStore.noteRating(run: run, record: record, score: score, settings: settings)
            }
            guard score >= 50 else { continue }
            if let verifyData = try? Data(contentsOf: run.appendingPathComponent("verify.json")),
               let verify = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
               let miss = (verify["pointerMissShare"] as? NSNumber)?.doubleValue,
               miss > 0
            {
                continue
            }
            guard let (_, record) = ConversationStore.load(from: run) else { continue }
            examples.append(contentsOf: trainingExamples(from: record, settings: settings))
        }
        if let data = try? JSONEncoder().encode(processed) {
            try? FS.atomicWrite(data, to: experienceURL)
        }
        return examples
    }

    private func trainingExamples(from record: ConversationRecord, settings: AgentSettings) -> [TrainingExample] {
        var result: [TrainingExample] = []
        for (index, message) in record.messages.enumerated() where message.role == "assistant" {
            guard let calls = message.toolCalls, !calls.isEmpty else { continue }
            var prefix = record
            prefix.messages = Array(record.messages[..<index])
            let window = ConversationWindow.build(
                record: prefix,
                recentCaptures: settings.recentCaptures,
                characterBudget: 32_000
            )
            let callText = calls.map { call in
                "<tool_call>{\"name\": \"\(call.name)\", \"arguments\": \(call.argumentsJSON)}</tool_call>"
            }.joined(separator: "\n")
            let target = [message.content, callText].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !target.isEmpty else { continue }
            let images = prefix.messages.last(where: { $0.isCapture })?.imagePaths ?? []
            result.append(
                TrainingExample(
                    systemPrompt: record.systemPrompt,
                    messages: window,
                    target: target,
                    imagePaths: images,
                    step: message.step,
                    gridColumns: record.grid.columns,
                    gridRows: record.grid.rows,
                    viewportWidth: record.viewport.width,
                    viewportHeight: record.viewport.height
                )
            )
        }
        return result
    }

    private func budgetReason(_ settings: AgentSettings) -> String? {
        if adapterStore.totalSteps >= settings.maxTrainingSteps {
            return "Step budget reached."
        }
        if adapterStore.consecutiveDiscards >= settings.maxConsecutiveDiscards {
            return "Candidate discard budget reached."
        }
        let limit = Int64(settings.maxDataDirectoryMegabytes) * 1_000_000
        if let size = directorySize(AppPaths.root), size > limit {
            return "Data directory budget reached."
        }
        return nil
    }

    private func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private func hash(of examples: [TrainingExample]) -> String {
        var hasher = Hasher()
        for example in examples {
            hasher.combine(example.target)
            hasher.combine(example.imagePaths)
        }
        return String(hasher.finalize())
    }

    private func set(
        state: String,
        step: Int? = nil,
        loss: Float? = nil,
        adapter: String? = nil,
        message: String
    ) {
        lock.lock()
        latestState = state
        if let step { latestStep = step }
        if let loss { latestLoss = loss }
        if let adapter { latestAdapter = adapter }
        latestMessage = message
        let update = TrainerUpdate(
            state: state,
            step: latestStep,
            loss: latestLoss,
            adapter: latestAdapter,
            message: message,
            elapsed: sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
        lock.unlock()
        onUpdate?(update)
    }
}
