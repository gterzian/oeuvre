import Foundation
@preconcurrency import MLX
import MLXLMCommon
import MLXVLM

public struct ModelReply: @unchecked Sendable {
    public var thinking: String
    /// False when generation stopped inside a reasoning block. The loop uses
    /// this to retry with thinking off instead of mistaking partial thought
    /// for the model's answer.
    public var thinkingComplete: Bool
    public var output: String
    public var toolCalls: [ToolCall]
    public var rejectedToolCall: String?
    public var promptTokens: Int
    public var cachedPromptTokens: Int
    public var generationTokens: Int
    public var timeToFirstToken: TimeInterval?
    public var generationTime: TimeInterval
    public var stopped: Bool

    public var tokensPerSecond: Double {
        guard generationTime > 0 else { return 0 }
        return Double(generationTokens) / generationTime
    }
}

public enum ModelRuntimeError: Error, LocalizedError {
    case noModelDirectory
    case failedToLoad(String)

    public var errorDescription: String? {
        switch self {
        case .noModelDirectory: "The model directory is not configured."
        case .failedToLoad(let message): "The model could not load: \(message)"
        }
    }
}

/// The MLX model and the chat-template renderer. The loop owns the model
/// weights; the harness asks this actor for one reply at a time.
public actor ModelRuntime {
    public struct Configuration: Sendable {
        public var modelDirectory: URL
        public var maxTokens: Int
        public var temperature: Float
        public var thinking: Bool
        public var imageDimension: Int
        public var tokenizerLoader: any TokenizerLoader

        public init(
            modelDirectory: URL,
            maxTokens: Int = 2_048,
            temperature: Float = 0.2,
            thinking: Bool = true,
            imageDimension: Int = 768,
            tokenizerLoader: any TokenizerLoader = HuggingFaceBridges.tokenizerLoader()
        ) {
            self.modelDirectory = modelDirectory
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.thinking = thinking
            self.imageDimension = imageDimension
            self.tokenizerLoader = tokenizerLoader
        }
    }

    private let configuration: Configuration
    private var containerTask: Task<ModelContainer, Error>?
    private var loadedAdapterID: String?
    private var loadedAdapter: (any ModelAdapter)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func prepare() async throws {
        _ = try await container()
    }

    public func loadAdapter(id: String?, directory: URL?) async throws {
        let targetID = directory == nil ? nil : (id ?? directory!.lastPathComponent)
        if targetID == loadedAdapterID { return }
        let container = try await container()
        let previous = loadedAdapter
        let next: (any ModelAdapter)? = try directory.map { try LoRAContainer.from(directory: $0) }
        try await container.perform { context in
            if let previous {
                context.model.unload(adapter: previous)
            }
            if let next {
                try context.model.load(adapter: next)
            }
        }
        loadedAdapter = next
        loadedAdapterID = targetID
    }

    /// One model turn over the supplied window. The last message is the turn
    /// that triggers generation; everything before it is history.
    public func generate(
        systemPrompt: String,
        history: [Chat.Message],
        tools: [ToolSpec],
        thinking: Bool? = nil
    ) async throws -> ModelReply {
        let container = try await container()
        let thinkingEnabled = thinking ?? configuration.thinking
        let parameters = GenerateParameters(
            maxTokens: configuration.maxTokens,
            temperature: configuration.temperature
        )
        let final = history.last ?? .user("Continue.")
        let prior = history.dropLast()
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            history: Array(prior),
            generateParameters: parameters,
            processing: UserInput.Processing(
                resize: CGSize(width: configuration.imageDimension, height: configuration.imageDimension)
            ),
            additionalContext: ["enable_thinking": thinkingEnabled],
            tools: tools,
            toolDispatch: nil
        )
        let started = Date()
        var firstToken: Date?
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var rejected: String?
        var promptTokens = 0
        var cachedTokens = 0
        var generationTokens = 0
        var stopped = false

        let stream = session.streamDetails(to: [final])
        var iterator = stream.makeAsyncIterator()
        while let generation = try await iterator.next() {
            switch generation {
            case .chunk(let chunk):
                if firstToken == nil { firstToken = Date() }
                text += chunk
            case .toolCall(let call):
                if firstToken == nil { firstToken = Date() }
                calls.append(call)
            case .rejectedToolCall(let rejection):
                rejected = rejection.reason.rawValue
            case .info(let info):
                promptTokens = info.promptTokenCount
                cachedTokens = info.cachedPromptTokenCount
                generationTokens = info.generationTokenCount
            }
        }
        if text.contains("<|im_end|>") || text.contains("</s>") {
            stopped = true
        }
        let parsed = Self.splitThinking(text, primed: thinkingEnabled)
        reasoning = parsed.thinking
        let output = parsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = Date()
        if generationTokens == 0 {
            generationTokens = max(1, (output + reasoning).split(separator: " ").count)
        }
        return ModelReply(
            thinking: reasoning,
            thinkingComplete: parsed.complete,
            output: output,
            toolCalls: calls,
            rejectedToolCall: rejected,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedTokens,
            generationTokens: generationTokens,
            timeToFirstToken: firstToken.map { $0.timeIntervalSince(started) },
            generationTime: end.timeIntervalSince(started),
            stopped: stopped
        )
    }

    public func containerForTraining() async throws -> ModelContainer {
        try await container()
    }

    private func container() async throws -> ModelContainer {
        if let containerTask {
            return try await containerTask.value
        }
        let directory = configuration.modelDirectory
        let loader = configuration.tokenizerLoader
        let task = Task {
            try await loadModelContainer(from: directory, using: loader)
        }
        containerTask = task
        do {
            return try await task.value
        } catch {
            containerTask = nil
            throw ModelRuntimeError.failedToLoad(error.localizedDescription)
        }
    }

    /// Split a generated turn into reasoning and answer. Qwen3.5's template
    /// prefills `<think>` into the prompt, so a completion that never emits
    /// `</think>` is reasoning that hit the token limit, not an answer.
    private static func splitThinking(
        _ text: String,
        primed: Bool
    ) -> (thinking: String, output: String, complete: Bool) {
        if let end = text.range(of: "</think>") {
            var thinking = String(text[..<end.lowerBound])
            if let start = thinking.range(of: "<think>") {
                thinking.removeSubrange(thinking.startIndex..<start.upperBound)
            }
            let output = String(text[end.upperBound...])
            return (thinking.trimmingCharacters(in: .whitespacesAndNewlines), output, true)
        }
        if let start = text.range(of: "<think>") {
            let thinking = String(text[start.upperBound...])
            return (thinking.trimmingCharacters(in: .whitespacesAndNewlines), "", false)
        }
        if primed {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "", false)
        }
        return ("", text, true)
    }
}
