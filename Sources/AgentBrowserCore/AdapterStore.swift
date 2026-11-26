import Foundation

struct AdapterManifest: Codable, Sendable {
    var id: String
    var baseModel: String
    var parentAdapter: String?
    var experienceHash: String
    var hyperparameters: [String: String]
    var systemPrompt: String
    var gridColumns: Int
    var gridRows: Int
    var viewportWidth: Double
    var viewportHeight: Double
    var recentCaptures: Int
    var createdAt: Date
    var status: String
}

struct AdapterStats: Codable, Sendable {
    var evaluationRuns: [String] = []
    var ratings: [Double] = []
    var activeRatings: [Double] = []

    var mean: Double? {
        ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)
    }

    var activeMean: Double? {
        activeRatings.isEmpty ? nil : activeRatings.reduce(0, +) / Double(activeRatings.count)
    }
}

/// The adapter store is the `adapters/` directory. One JSON file names the
/// active and candidate adapters; each adapter directory carries a manifest
/// and the LoRA files the runtime loads.
final class AdapterStore: @unchecked Sendable {
    private let lock = NSLock()

    struct State: Codable {
        var active: String?
        var candidate: String?
        var consecutiveDiscards: Int = 0
        var stats: [String: AdapterStats] = [:]
        var discarded: [String] = []
        var totalSteps: Int = 0
    }

    private var state: State

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let state = try? JSONDecoder().decode(State.self, from: data)
        {
            self.state = state
        } else {
            self.state = State()
        }
    }

    private static var stateURL: URL {
        AppPaths.adapters.appendingPathComponent("state.json")
    }

    var activeID: String? {
        lock.lock(); defer { lock.unlock() }
        return state.active
    }

    var candidateID: String? {
        lock.lock(); defer { lock.unlock() }
        return state.candidate
    }

    var consecutiveDiscards: Int {
        lock.lock(); defer { lock.unlock() }
        return state.consecutiveDiscards
    }

    var totalSteps: Int {
        lock.lock(); defer { lock.unlock() }
        return state.totalSteps
    }

    func directory(for id: String?) -> URL? {
        guard let id else { return nil }
        let url = AppPaths.adapters.appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func choose(candidateProbability: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let candidate = state.candidate, Double.random(in: 0..<1) < candidateProbability {
            return candidate
        }
        return state.active
    }

    func manifest(for id: String) -> AdapterManifest? {
        loadManifest(id)
    }

    func allAdapters() -> [AdapterManifest] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.adapters,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { loadManifest($0.lastPathComponent) }
    }

    func noteRating(run: URL, record: ConversationRecord, score: Double, settings: AgentSettings) {
        lock.lock()
        let adapter = record.adapterID ?? state.active ?? "base"
        var stats = state.stats[adapter] ?? AdapterStats()
        if adapter == state.candidate {
            stats.evaluationRuns.append(run.path)
            stats.ratings.append(score)
        } else {
            stats.activeRatings.append(score)
        }
        state.stats[adapter] = stats
        let candidate = state.candidate
        let shouldPromote = candidate != nil
            && stats.evaluationRuns.count >= settings.candidateEvaluationRuns
            && (stats.mean ?? 0) >= ((stats.activeMean ?? 0) + settings.candidateMargin)
            && !stats.ratings.contains(0)
        let shouldDiscard = candidate != nil
            && stats.evaluationRuns.count >= settings.candidateEvaluationRuns
            && !shouldPromote
        if shouldPromote, let candidate {
            state.active = candidate
            state.candidate = nil
            state.consecutiveDiscards = 0
            updateManifestStatus(candidate, status: "active")
        } else if shouldDiscard, let candidate {
            state.candidate = nil
            state.consecutiveDiscards += 1
            state.discarded.append(candidate)
            updateManifestStatus(candidate, status: "discarded")
        }
        let snapshot = state
        lock.unlock()
        save(snapshot)
    }

    func promoteCandidate(id: String) {
        lock.lock()
        state.candidate = id
        state.stats[id] = AdapterStats()
        let snapshot = state
        lock.unlock()
        save(snapshot)
        updateManifestStatus(id, status: "candidate")
    }

    func addSteps(_ count: Int) {
        lock.lock()
        state.totalSteps += count
        let snapshot = state
        lock.unlock()
        save(snapshot)
    }

    private func updateManifestStatus(_ id: String, status: String) {
        guard var manifest = loadManifest(id) else { return }
        manifest.status = status
        write(manifest)
    }

    private func loadManifest(_ id: String) -> AdapterManifest? {
        let url = AppPaths.adapters.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AdapterManifest.self, from: data)
    }

    func write(_ manifest: AdapterManifest) {
        let directory = AppPaths.adapters.appendingPathComponent(manifest.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(manifest) {
            try? FS.atomicWrite(data, to: directory.appendingPathComponent("manifest.json"))
        }
    }

    private func save(_ state: State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? FS.atomicWrite(data, to: Self.stateURL)
        }
    }
}
