import AgentBrowserModel
import Foundation
import MLXLMCommon

struct LoopState: Sendable {
    var status: TaskStatus
    var finalReply: String
    var stepCount: Int
    var turnCount: Int
    var conversationPath: String
    var trajectoryDirectory: String
    var steps: [StepRecord]
}

final class AgentLoop: @unchecked Sendable {
    let conversation: ConversationStore
    let runtime: ModelRuntime
    private let engine: EngineBridge
    private let captureService: CaptureService
    private let settings: AgentSettings
    private let entries: EntryStore
    private let lock = NSLock()
    private var runTask: Task<Void, Never>?
    private var stopRequested = false
    private var pendingPersonMessages: [String] = []
    private var status: TaskStatus
    private var finalReply: String
    private var captureIndex = 0
    private var nextStep = 1

    var onEntry: ((DebugEntry) -> Void)?
    var onCapture: ((Capture) -> Void)?
    var onStepsChanged: (([StepRecord]) -> Void)?
    var onFinished: ((LoopState) -> Void)?
    var onStatusChanged: ((TaskStatus, String) -> Void)?

    init(
        conversation: ConversationStore,
        runtime: ModelRuntime,
        engine: EngineBridge,
        captureService: CaptureService,
        settings: AgentSettings,
        entries: EntryStore
    ) {
        self.conversation = conversation
        self.runtime = runtime
        self.engine = engine
        self.captureService = captureService
        self.settings = settings
        self.entries = entries
        let record = conversation.current
        self.status = record.status
        self.finalReply = record.finalReply
        self.nextStep = max(1, record.stepCount + 1)
        self.captureIndex = record.messages.filter { $0.isCapture }.count
    }

    var state: LoopState {
        lock.lock()
        defer { lock.unlock() }
        let record = conversation.current
        return LoopState(
            status: status,
            finalReply: finalReply,
            stepCount: record.stepCount,
            turnCount: record.turnCount ?? 0,
            conversationPath: conversation.conversationURL.path,
            trajectoryDirectory: conversation.directory.path,
            steps: record.steps
        )
    }

    func start(resume: Bool) {
        lock.lock()
        guard runTask == nil else {
            lock.unlock()
            return
        }
        stopRequested = false
        status = .running
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(resume: resume)
        }
        runTask = task
        lock.unlock()
        setStatus(.running, finalReply: "")
    }

    func stop(notify: Bool = true) {
        lock.lock()
        stopRequested = true
        lock.unlock()
        runTask?.cancel()
        finish(status: .stopped, reply: notify ? "Stopped by the person." : "Stopped for a new task.", notify: notify)
    }

    func sendPersonMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        pendingPersonMessages.append(text)
        lock.unlock()
    }

    // MARK: - Loop

    private func run(resume: Bool) async {
        do {
            guard await engine.waitUntilReady() else {
                finish(status: .stopped, reply: "The agent tab did not open.")
                return
            }
            let record = conversation.current
            if !record.lastURL.isEmpty, record.lastURL != engine.url {
                _ = engine.navigate(to: record.lastURL)
            }
            let adapterID = record.adapterID ?? settings.adapterID
            try await runtime.loadAdapter(
                id: adapterID,
                directory: adapterID.flatMap { id in
                    AppPaths.adapters.appendingPathComponent(id, isDirectory: true)
                }
            )
            if !resume || record.messages.last?.isCapture != true {
                let capture = await captureService.captureAfterActions(step: 0)
                appendCapture(capture, step: 0, resultText: "Initial capture.")
            }
            await loop()
        } catch {
            finish(status: .stopped, reply: "The task stopped: \(error.localizedDescription)")
        }
    }

    private func loop() async {
        var retriedWithoutThinking = false
        while true {
            if Task.isCancelled || isStopped { return }
            drainPersonMessages()

            let record = conversation.current
            if !engine.url.isEmpty {
                conversation.update { $0.lastURL = engine.url }
            }
            let window = ConversationWindow.build(
                record: record,
                recentCaptures: settings.recentCaptures,
                characterBudget: 48_000
            )
            guard !window.isEmpty else { return }
            let step = max(1, record.stepCount + 1)
            conversation.update { $0.turnCount = ($0.turnCount ?? 0) + 1 }
            let requestEntry = DebugEntry(
                step: step,
                kind: .request,
                summary: "Prompt \(window.count) messages, \(window.reduce(0) { $0 + ($1.images.isEmpty ? 0 : $1.images.count) }) images",
                promptText: renderPrompt(window)
            )
            recordEntry(requestEntry)

            let reply: ModelReply
            do {
                reply = try await runtime.generate(
                    systemPrompt: record.systemPrompt,
                    history: window,
                    tools: BrowserPrompt.tools,
                    thinking: retriedWithoutThinking ? false : nil
                )
            } catch {
                finish(status: .stopped, reply: "The model failed: \(error.localizedDescription)")
                return
            }

            if let thinking = reply.thinking.nilIfEmpty {
                recordEntry(
                    DebugEntry(
                        step: step,
                        kind: .thinking,
                        summary: "Thinking \(thinking.count) characters",
                        thinking: thinking
                    )
                )
            }
            recordEntry(
                DebugEntry(
                    step: step,
                    kind: .output,
                    summary: reply.output.isEmpty ? "No text output" : reply.output.prefix(120).description,
                    duration: reply.generationTime,
                    promptTokens: reply.promptTokens,
                    replyTokens: reply.generationTokens,
                    output: reply.output,
                    toolCallsJSON: reply.toolCalls.isEmpty ? nil : JSON.string(reply.toolCalls.map { call in
                        ["name": call.function.name, "arguments": call.function.arguments.mapValues { $0.anyValue }]
                    }),
                    timeToFirstToken: reply.timeToFirstToken,
                    generationTime: reply.generationTime
                )
            )

            let toolCalls = reply.toolCalls
            // Reasoned past the token budget without answering or acting. Do
            // not store a half thought as the final reply; ask once more with
            // thinking off so the model produces an action or a short answer.
            if toolCalls.isEmpty, reply.output.isEmpty, !reply.thinkingComplete,
               !retriedWithoutThinking
            {
                recordEntry(
                    DebugEntry(
                        step: step,
                        kind: .thinking,
                        summary: "Reasoning reached the token limit; retrying without thinking"
                    )
                )
                retriedWithoutThinking = true
                continue
            }

            let assistant = StoredMessage(
                role: "assistant",
                content: reply.output,
                toolCalls: toolCalls.map {
                    StoredToolCall(name: $0.function.name, arguments: $0.function.arguments, id: $0.id)
                },
                step: step
            )
            conversation.append(assistant)
            retriedWithoutThinking = false

            if toolCalls.isEmpty {
                if let rejected = reply.rejectedToolCall {
                    finish(status: .stopped, reply: "The model produced a rejected tool call: \(rejected)")
                } else {
                    finish(status: .finished, reply: reply.output.isEmpty ? "The task finished." : reply.output)
                }
                return
            }

            var captures: [Capture] = []
            var resultLines: [String] = []
            var notes: [String] = []
            for call in toolCalls {
                if isStopped { return }
                recordEntry(
                    DebugEntry(
                        step: step,
                        kind: .toolCall,
                        summary: summary(of: call),
                        toolCallsJSON: JSON.string(["name": call.function.name, "arguments": call.function.arguments.mapValues { $0.anyValue }])
                    )
                )
                let result = await apply(call: call, step: step)
                resultLines.append(contentsOf: result.resultLines)
                if let capture = result.capture { captures.append(capture) }
                if let note = result.note { notes.append(note) }
                conversation.append(
                    StoredMessage(
                        role: "tool",
                        content: result.resultText,
                        toolCallID: call.id,
                        toolName: call.function.name,
                        step: step
                    )
                )
                recordEntry(
                    DebugEntry(
                        step: step,
                        kind: .toolResult,
                        summary: result.resultText.prefix(140).description,
                        resultText: result.resultText,
                        capturePath: nil
                    )
                )
            }

            var capturePaths: [String] = []
            if !captures.isEmpty {
                capturePaths = appendCaptures(captures, step: step, resultText: "A capture follows.")
            }
            let stepRecord = StepRecord(
                index: step,
                note: notes.joined(separator: " "),
                actionSummaries: resultLines,
                resultLines: resultLines,
                capturePaths: capturePaths,
                timestamp: Date(),
                duration: reply.generationTime
            )
            conversation.appendStep(stepRecord)
            onStepsChanged?(conversation.current.steps)
            drainPersonMessages()
            if isStopped { return }
        }
    }

    private struct ToolOutcome {
        var resultText: String
        var resultLines: [String]
        var capture: Capture?
        var note: String?
    }

    private func apply(call: ToolCall, step: Int) async -> ToolOutcome {
        let arguments = call.function.arguments.mapValues { $0.anyValue }
        switch call.function.name {
        case "act":
            let note = arguments["note"] as? String ?? ""
            let actions = ActionParser.parse(arguments: arguments)
            if actions.isEmpty {
                return ToolOutcome(
                    resultText: "act: no valid actions. A capture follows.",
                    resultLines: ["no valid actions"],
                    capture: await captureService.captureAfterActions(step: step),
                    note: note
                )
            }
            var lines: [String] = []
            var capture: Capture?
            let firstWait = actions.firstIndex { if case .wait = $0 { return true } else { return false } }
            if let firstWait {
                let prefix = Array(actions[..<firstWait])
                if !prefix.isEmpty {
                    lines.append(contentsOf: ActionPlayer.apply(prefix, grid: captureService.grid, engine: engine))
                }
                switch actions[firstWait] {
                case .wait(.milliseconds(let milliseconds)):
                    lines.append("\(firstWait + 1) wait \(milliseconds) ms: delivered")
                    capture = await captureService.wait(milliseconds: milliseconds)
                case .wait(.change(let maxMilliseconds)):
                    lines.append("\(firstWait + 1) wait until change, max \(maxMilliseconds) ms: delivered")
                    let outcome = await captureService.waitUntilChange(maxMilliseconds: maxMilliseconds, step: step)
                    capture = outcome.0
                    lines.append(outcome.1 ? "the page changed" : "the page showed no visible change")
                default:
                    break
                }
                let suffix = Array(actions[(firstWait + 1)...])
                if !suffix.isEmpty {
                    lines.append(contentsOf: ActionPlayer.apply(suffix, grid: captureService.grid, engine: engine))
                    capture = await captureService.captureAfterActions(step: step)
                }
            } else {
                lines.append(contentsOf: ActionPlayer.apply(actions, grid: captureService.grid, engine: engine))
                capture = await captureService.captureAfterActions(step: step)
            }
            let result = "\(lines.joined(separator: "\n"))\n\(capture?.caption ?? "settled")\nA capture follows."
            return ToolOutcome(resultText: result, resultLines: lines, capture: capture, note: note)

        case "capture":
            let region = parseRegion(arguments["region"] as? String)
            let frames = Int((arguments["frames"] as? NSNumber)?.intValue ?? 1)
            let captures = await captureService.captureNow(step: step, region: region, frames: frames)
            return ToolOutcome(
                resultText: "Capture follows. \(captures.last?.caption ?? "")",
                resultLines: ["capture requested"],
                capture: captures.last,
                note: nil
            )

        default:
            return ToolOutcome(
                resultText: "Unknown tool \(call.function.name).",
                resultLines: ["unknown tool \(call.function.name)"],
                capture: nil,
                note: nil
            )
        }
    }

    private func parseRegion(_ text: String?) -> CGRect? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let grid = captureService.grid
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 1 {
            return grid.cellRect(label: parts[0])
        }
        guard let start = grid.cellRect(label: parts[0]),
              let end = grid.cellRect(label: parts[1])
        else { return nil }
        return start.union(end)
    }

    // MARK: - Messages and state

    private func drainPersonMessages() {
        lock.lock()
        let messages = pendingPersonMessages
        pendingPersonMessages.removeAll()
        lock.unlock()
        for message in messages {
            let step = conversation.current.stepCount
            conversation.append(
                StoredMessage(role: "user", content: message, step: step)
            )
            recordEntry(
                DebugEntry(step: step, kind: .personMessage, summary: message.prefix(120).description)
            )
        }
    }

    @discardableResult
    private func appendCapture(_ capture: Capture, step: Int, resultText: String) -> [String] {
        appendCaptures([capture], step: step, resultText: resultText)
    }

    @discardableResult
    private func appendCaptures(_ captures: [Capture], step: Int, resultText: String) -> [String] {
        var paths: [String] = []
        for capture in captures {
            let url = conversation.writeCapture(capture, step: step, index: captureIndex)
            captureIndex += 1
            paths.append(url.path)
        }
        let caption = captures.last?.caption ?? ""
        conversation.append(
            StoredMessage(
                role: "user",
                content: resultText + " " + caption,
                imagePaths: paths,
                step: step
            )
        )
        if let path = paths.last {
            recordEntry(
                DebugEntry(
                    step: step,
                    kind: .capture,
                    summary: caption,
                    capturePath: path
                )
            )
            if let last = captures.last { onCapture?(last) }
        }
        return paths
    }

    private func recordEntry(_ entry: DebugEntry) {
        entries.append(entry)
        onEntry?(entry)
    }

    private func finish(status: TaskStatus, reply: String, notify: Bool = true) {
        lock.lock()
        guard self.status != .finished && self.status != .stopped else {
            lock.unlock()
            return
        }
        self.status = status
        self.finalReply = reply
        let task = runTask
        runTask = nil
        stopRequested = true
        lock.unlock()
        task?.cancel()
        conversation.update { record in
            record.status = status
            record.finalReply = reply
            record.lastURL = engine.url
        }
        let state = self.state
        onFinished?(state)
        if notify {
            onStatusChanged?(status, reply)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested || Task.isCancelled
    }

    private func setStatus(_ status: TaskStatus, finalReply: String) {
        onStatusChanged?(status, finalReply)
    }

    private func summary(of call: ToolCall) -> String {
        let arguments = call.function.arguments.mapValues { $0.anyValue }
        switch call.function.name {
        case "act":
            let note = arguments["note"] as? String ?? ""
            return "act \(ActionParser.summary(arguments: arguments)) — \(note.prefix(80))"
        case "capture":
            return "capture \(arguments["region"] ?? "")"
        default:
            return call.function.name
        }
    }

    private func renderPrompt(_ window: [Chat.Message]) -> String {
        window.enumerated().map { index, message in
            let images = message.images.isEmpty ? "" : " [\(message.images.count) image(s)]"
            return "[\(index + 1)] \(message.role.rawValue): \(message.content)\(images)"
        }.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
