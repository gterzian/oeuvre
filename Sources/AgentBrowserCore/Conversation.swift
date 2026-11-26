import Foundation
import MLXLMCommon

enum TaskStatus: String, Codable, Sendable {
    case running
    case finished
    case stopped
}

struct StoredToolCall: Codable, Sendable, Equatable {
    var name: String
    var argumentsJSON: String
    var id: String?

    init(name: String, arguments: [String: JSONValue], id: String? = nil) {
        self.name = name
        self.argumentsJSON = JSON.string(arguments.mapValues { $0.anyValue })
        self.id = id
    }

    var arguments: [String: Any] {
        JSON.object(argumentsJSON)
    }

    func toolCall() -> ToolCall {
        let values = arguments.mapValues { JSONValue.from($0) }
        return ToolCall(function: .init(name: name, arguments: values), id: id)
    }
}

struct StoredMessage: Codable, Sendable {
    var id: String = UUID().uuidString
    var role: String
    var content: String
    var imagePaths: [String] = []
    var toolCalls: [StoredToolCall]? = nil
    var toolCallID: String? = nil
    var toolName: String? = nil
    var step: Int
    var timestamp: Date = Date()

    func chatMessage() -> Chat.Message {
        let images = imagePaths.map { UserInput.Image.url(URL(fileURLWithPath: $0)) }
        switch role {
        case "assistant":
            return .assistant(content, toolCalls: toolCalls?.map { $0.toolCall() })
        case "tool":
            return .tool(content, id: toolCallID, name: toolName)
        case "system":
            return .system(content, images: images)
        default:
            return .user(content, images: images)
        }
    }

    var isCapture: Bool { !imagePaths.isEmpty }
}

struct StepRecord: Codable, Sendable {
    var index: Int
    var note: String
    var actionSummaries: [String]
    var resultLines: [String]
    var capturePaths: [String]
    var timestamp: Date
    var duration: TimeInterval
}

struct ConversationRecord: Codable, Sendable {
    var version: Int = 1
    var id: String = UUID().uuidString
    var task: String
    var siteLabel: String
    var seed: String?
    var adapterID: String?
    var systemPrompt: String
    var status: TaskStatus = .running
    var messages: [StoredMessage] = []
    var steps: [StepRecord] = []
    var finalReply: String = ""
    var lastURL: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var stepCount: Int = 0
    /// Model turns, counted separately from action batches. A turn that ends
    /// without a tool call still consumes the task's budget.
    var turnCount: Int? = nil
    var grid: GridDescriptor
    var viewport: CGSize
}

/// The conversation file. Every append reaches disk, so a crash loses at most
/// the message in flight. A tool call in flight when the app stopped is marked
/// interrupted on the next load.
final class ConversationStore: @unchecked Sendable {
    let directory: URL
    let conversationURL: URL
    private let lock = NSLock()
    private var record: ConversationRecord

    init(directory: URL, record: ConversationRecord) {
        self.directory = directory
        self.conversationURL = directory.appendingPathComponent("conversation.json")
        self.record = record
    }

    var current: ConversationRecord {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func update(_ body: (inout ConversationRecord) -> Void) {
        lock.lock()
        body(&record)
        record.updatedAt = Date()
        let snapshot = record
        lock.unlock()
        save(snapshot)
    }

    func append(_ message: StoredMessage) {
        update { $0.messages.append(message) }
    }

    func appendStep(_ step: StepRecord) {
        update { record in
            record.steps.append(step)
            record.stepCount = step.index
        }
    }

    func save(_ record: ConversationRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FS.atomicWrite(data, to: conversationURL)
    }

    func capturePath(step: Int, index: Int) -> URL {
        let captures = directory.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        return captures.appendingPathComponent("step-\(step)-\(index).png")
    }

    func writeCapture(_ capture: Capture, step: Int, index: Int) -> URL {
        let url = capturePath(step: step, index: index)
        try? capture.png.write(to: url, options: .atomic)
        return url
    }

    static func load(from directory: URL) -> (ConversationStore, ConversationRecord)? {
        let url = directory.appendingPathComponent("conversation.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var record = try? decoder.decode(ConversationRecord.self, from: data) else { return nil }
        if record.status == .running {
            record.messages = record.messages.map { message in
                guard message.role == "assistant", message.toolCalls != nil else { return message }
                return message
            }
        }
        return (ConversationStore(directory: directory, record: record), record)
    }
}

/// The window the model receives. It always holds the system prompt and task,
/// the newest captures as images, and every note; older captures become a line
/// of text, and the oldest steps collapse into one summary message when the
/// context outgrows the model.
enum ConversationWindow {
    static func build(
        record: ConversationRecord,
        recentCaptures: Int,
        characterBudget: Int
    ) -> [Chat.Message] {
        var messages = record.messages
        guard !messages.isEmpty else {
            return [.user(record.task)]
        }
        let captureIndices = messages.indices.filter { messages[$0].isCapture }
        let dropImages = Set(captureIndices.dropLast(max(0, recentCaptures)))
        for index in dropImages {
            let step = messages[index].step
            messages[index].imagePaths = []
            messages[index].content = "Capture of step \(step) omitted. \(messages[index].content)"
        }

        var total = messages.reduce(0) { $0 + $1.content.count }
        var summaryNotes: [String] = []
        while total > characterBudget, messages.count > 3 {
            // Remove the oldest complete step after the task message.
            let removeIndex = messages.firstIndex { $0.step > 0 } ?? 1
            let step = messages[removeIndex].step
            while messages.count > 1, messages[removeIndex].step == step {
                let removed = messages.remove(at: min(removeIndex, messages.count - 1))
                total -= removed.content.count
                if removed.role == "assistant", let call = removed.toolCalls?.first,
                   let note = call.arguments["note"] as? String
                {
                    summaryNotes.append("Step \(step): \(note)")
                }
            }
        }
        var result: [Chat.Message] = []
        if !summaryNotes.isEmpty {
            result.append(.user("Summary of earlier steps:\n" + summaryNotes.joined(separator: "\n")))
        }
        result.append(contentsOf: messages.map { $0.chatMessage() })
        return result
    }
}
