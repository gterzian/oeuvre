import Foundation

/// The one directory the app and the test skill share. It lives outside the
/// repository: environments, trajectories, adapters and the journal survive
/// restarts and are never committed.
enum AppPaths {
    static var root: URL {
        if let path = LaunchOptions.shared.dataDirectory, !path.isEmpty {
            return URL(
                fileURLWithPath: NSString(string: path).expandingTildeInPath,
                isDirectory: true
            )
        }
        if let override = ProcessInfo.processInfo.environment["AGENT_BROWSER_DATA_DIR"],
           !override.isEmpty
        {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("agent-browser", isDirectory: true)
    }

    static var environments: URL { root.appendingPathComponent("environments", isDirectory: true) }
    static var trajectories: URL { root.appendingPathComponent("trajectories", isDirectory: true) }
    static var adapters: URL { root.appendingPathComponent("adapters", isDirectory: true) }
    static var journal: URL { root.appendingPathComponent("journal.md") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static func prepare() throws {
        for directory in [root, environments, trajectories, adapters] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func newRunDirectory(label: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = label.isEmpty ? "run" : label.replacingOccurrences(of: "/", with: "-")
        let url = trajectories.appendingPathComponent("\(formatter.string(from: Date()))-\(safe)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Settings the person changes in the settings window. The trainer's budget is
/// stored as whole units so a JSON file stays readable.
struct AgentSettings: Codable, Sendable {
    var adapterID: String? = nil
    var modelDirectory: String? = nil
    var recentCaptures: Int = 3
    var cellSizePoints: Int = 64
    var keepLowScoreCapturesDays: Int = 7
    var trainingEnabled: Bool = false
    var maxTrainingSteps: Int = 20_000
    var maxDataDirectoryMegabytes: Int = 4_096
    var maxConsecutiveDiscards: Int = 3
    var trainingSessionExamples: Int = 128
    var trainingBatchSize: Int = 1
    var checkpointEverySteps: Int = 20
    var candidateEvaluationRuns: Int = 8
    var candidateMargin: Double = 0.05
    var candidateAssignmentProbability: Double = 0.2

    static let defaults = AgentSettings()

    static func load() -> AgentSettings {
        guard let data = try? Data(contentsOf: AppPaths.settingsFile),
              let settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else { return .defaults }
        return settings
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: AppPaths.settingsFile, options: .atomic)
        }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    static func object(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum FS {
    static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    static func atomicWrite(_ text: String, to url: URL) throws {
        try atomicWrite(Data(text.utf8), to: url)
    }
}

enum AgentLog {
    private static let queue = DispatchQueue(label: "agent-browser.log")

    /// Write to stderr and to the data directory's app.log. The file matters
    /// when the app is started through `open`: LaunchServices does not keep
    /// the parent's stderr, and the test skill reads app.log.
    static func write(_ message: String) {
        let line = "[agent-browser] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let root = AppPaths.root
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("app.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
