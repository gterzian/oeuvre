import Foundation

enum EntryKind: String, Codable, Sendable, CaseIterable {
    case systemPrompt
    case task
    case personMessage
    case request
    case thinking
    case output
    case toolCall
    case toolResult
    case capture
}

struct DebugEntry: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var step: Int
    var time: Date = Date()
    var kind: EntryKind
    var summary: String
    var duration: TimeInterval?
    var promptTokens: Int?
    var replyTokens: Int?
    var promptText: String?
    var thinking: String?
    var output: String?
    var toolCallsJSON: String?
    var resultText: String?
    var capturePath: String?
    var timeToFirstToken: TimeInterval?
    var generationTime: TimeInterval?
}

/// The debug panel reads the same entries the loop writes. Clearing the view
/// hides them; the conversation file stays as it is.
final class EntryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DebugEntry] = []
    private var hiddenBefore: Date?

    func append(_ entry: DebugEntry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [DebugEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let hiddenBefore else { return entries }
        return entries.filter { $0.time >= hiddenBefore }
    }

    func clearView() {
        lock.lock()
        hiddenBefore = Date()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        hiddenBefore = nil
        lock.unlock()
    }
}
