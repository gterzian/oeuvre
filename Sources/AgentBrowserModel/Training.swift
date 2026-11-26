import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers

public struct TrainingExample: @unchecked Sendable {
    public var systemPrompt: String
    public var messages: [Chat.Message]
    public var target: String
    public var imagePaths: [String]
    public var step: Int
    public var gridColumns: Int
    public var gridRows: Int
    public var viewportWidth: Double
    public var viewportHeight: Double

    public init(
        systemPrompt: String,
        messages: [Chat.Message],
        target: String,
        imagePaths: [String],
        step: Int,
        gridColumns: Int = 0,
        gridRows: Int = 0,
        viewportWidth: Double = 0,
        viewportHeight: Double = 0
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.target = target
        self.imagePaths = imagePaths
        self.step = step
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

public struct TrainingConfiguration: Sendable {
    public var checkpointEvery: Int
    public var adapterConfig: LoRAConfiguration
    public var learningRate: Float

    public init(
        checkpointEvery: Int = 20,
        adapterConfig: LoRAConfiguration = .init(
            numLayers: 4,
            loraParameters: .init(rank: 8, scale: 10.0, dropout: 0.0)
        ),
        learningRate: Float = 1e-5
    ) {
        self.checkpointEvery = checkpointEvery
        self.adapterConfig = adapterConfig
        self.learningRate = learningRate
    }
}

public struct TrainingUpdate: Sendable {
    public var step: Int
    public var loss: Float
    public var checkpoint: URL?
}

extension ModelRuntime {
    /// Run one LoRA training session over `examples`. The container lock is
    /// held for the session, but the loop stops at the current step boundary
    /// as soon as `shouldStop` returns true, so a task waits at most one
    /// step. The adapter layers are removed before the method returns.
    public func train(
        examples: [TrainingExample],
        adapterDirectory: URL,
        parentAdapterDirectory: URL?,
        configuration: TrainingConfiguration,
        shouldStop: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (TrainingUpdate) -> Void
    ) async throws {
        guard !examples.isEmpty else { return }
        let container = try await containerForTraining()
        var prepared = try AdapterFiles.prepare(
            adapterDirectory: adapterDirectory,
            configuration: configuration,
            parentAdapterDirectory: parentAdapterDirectory,
            examples: examples
        )
        let initialStep = prepared.step
        let adaptersURL = prepared.adaptersURL
        let parentWeights = parentAdapterDirectory
            .map { $0.appendingPathComponent("adapters.safetensors") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let finalStep = try await container.perform { (context: ModelContext) async throws -> Int in
            let languageModel = context.model
            let adapter: LoRAContainer
            do {
                adapter = try LoRAContainer.from(
                    model: languageModel,
                    configuration: configuration.adapterConfig
                )
                if initialStep > 0, FileManager.default.fileExists(atPath: adaptersURL.path) {
                    try LoRATrain.loadLoRAWeights(model: context.model, url: adaptersURL)
                } else if let parentWeights {
                    try LoRATrain.loadLoRAWeights(model: context.model, url: parentWeights)
                }
            }
            defer {
                context.model.unload(adapter: adapter)
            }
            let optimizer = Adam(learningRate: configuration.learningRate)
            let tokenizer = context.tokenizer
            let model = context.model
            let wasTraining = model.training
            model.train()
            var totalLoss: Float = 0
            var lossCount = 0
            var step = initialStep
            for example in examples {
                if shouldStop() { break }
                let promptMessages = [Chat.Message.system(example.systemPrompt)]
                    + example.messages
                let promptInput = try await context.processor.prepare(
                    input: UserInput(chat: promptMessages, tools: nil)
                )
                var fullMessages = promptMessages
                fullMessages.append(.assistant(example.target))
                let fullInput = try await context.processor.prepare(
                    input: UserInput(chat: fullMessages, tools: nil)
                )
                let promptCount = promptInput.text.tokens.dim(-1)
                let fullTokens = fullInput.text.tokens
                let length = fullTokens.dim(-1)
                guard length > promptCount + 1 else { continue }
                let lossValue = Self.trainingStep(
                    model: model,
                    optimizer: optimizer,
                    input: fullInput,
                    promptCount: promptCount,
                    length: length
                )
                totalLoss += lossValue
                lossCount += 1
                step += 1
                let checkpoint: URL?
                if step % configuration.checkpointEvery == 0 {
                    checkpoint = adaptersURL
                    try LoRATrain.saveLoRAWeights(model: model, url: adaptersURL)
                } else {
                    checkpoint = nil
                }
                progress(TrainingUpdate(
                    step: step,
                    loss: lossCount > 0 ? totalLoss / Float(lossCount) : 0,
                    checkpoint: checkpoint
                ))
                _ = tokenizer
                if shouldStop() { break }
            }
            model.train(wasTraining)
            return step
        }
        prepared.step = finalStep
        try AdapterFiles.finish(prepared)
    }

    private nonisolated static func trainingStep(
        model: Module,
        optimizer: Adam,
        input: LMInput,
        promptCount: Int,
        length: Int
    ) -> Float {
        let lossAndGrad = valueAndGrad(model: model) { model, _ in
            guard let languageModel = model as? any LanguageModel else {
                return [MLXArray(Float(0))]
            }
            guard case .logits(let output) = try? languageModel.prepare(
                input,
                cache: [],
                state: nil,
                prefill: .init(chunking: .unchunked)
            ) else {
                return [MLXArray(Float(0))]
            }
            let logits = output.logits[0..., 0..<(length - 1), 0...]
            let targets = input.text.tokens[0..., 1...]
            let weights = MLXArray(
                (0..<(length - 1)).map { $0 >= promptCount - 1 ? Float(1) : Float(0) }
            ).reshaped(1, length - 1)
            let loss = crossEntropy(
                logits: logits,
                targets: targets,
                weights: weights,
                reduction: .mean
            )
            return [loss]
        }
        let (values, gradients) = lossAndGrad(model, [])
        optimizer.update(model: model, gradients: gradients)
        eval(model, optimizer, values[0])
        return values[0].item(Float.self)
    }
}

enum TrainError: Error, LocalizedError {
    case modelIsNotLanguageModel
    case noExamples

    var errorDescription: String? {
        switch self {
        case .modelIsNotLanguageModel: "The loaded model is not a language model."
        case .noExamples: "No training examples."
        }
    }
}

private struct AdapterFiles {
    var step: Int
    var adaptersURL: URL
}

private extension AdapterFiles {
    static func prepare(
        adapterDirectory: URL,
        configuration: TrainingConfiguration,
        parentAdapterDirectory: URL?,
        examples: [TrainingExample]
    ) throws -> AdapterFiles {
        try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "fine_tune_type": "lora",
            "num_layers": configuration.adapterConfig.numLayers,
            "lora_parameters": [
                "rank": configuration.adapterConfig.loraParameters.rank,
                "scale": configuration.adapterConfig.loraParameters.scale,
                "dropout": configuration.adapterConfig.loraParameters.dropout,
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: adapterDirectory.appendingPathComponent("adapter_config.json"), options: .atomic)
        let checkpoint = adapterDirectory.appendingPathComponent("checkpoint.json")
        var step = 0
        if let data = try? Data(contentsOf: checkpoint),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["step"] as? Int
        {
            step = value
        }
        let parentWeights = parentAdapterDirectory
            .map { $0.appendingPathComponent("adapters.safetensors") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if step > 0 {
            let weights = adapterDirectory.appendingPathComponent("adapters.safetensors")
            if FileManager.default.fileExists(atPath: weights.path) {
                return AdapterFiles(step: step, adaptersURL: weights)
            }
        }
        if let parentWeights {
            try? FileManager.default.removeItem(at: adapterDirectory.appendingPathComponent("adapters.safetensors"))
            _ = parentWeights
        }
        _ = examples
        return AdapterFiles(step: step, adaptersURL: adapterDirectory.appendingPathComponent("adapters.safetensors"))
    }

    static func finish(_ files: AdapterFiles) throws {
        let checkpoint = files.adaptersURL.deletingLastPathComponent().appendingPathComponent("checkpoint.json")
        let data = try JSONSerialization.data(
            withJSONObject: ["step": files.step],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: checkpoint, options: .atomic)
    }
}
