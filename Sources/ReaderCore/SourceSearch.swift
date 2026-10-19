import Foundation

public struct SourceSearchRequest: Sendable {
    public let source: BookSource
    public let page: Int
    public init(source: BookSource, page: Int) { self.source = source; self.page = page }
}

public struct SourceSearchOutcome: Sendable {
    public let sourceID: String
    public let sourceName: String
    public let page: Int
    public let novels: [OnlineNovel]
    public let failure: String?
    public let elapsedMilliseconds: Int?
    public init(sourceID: String, sourceName: String, page: Int, novels: [OnlineNovel], failure: String? = nil, elapsedMilliseconds: Int? = nil) {
        self.sourceID = sourceID; self.sourceName = sourceName; self.page = page; self.novels = novels; self.failure = failure
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct SourceSearchHit: Identifiable, Sendable {
    public let novel: OnlineNovel
    public let sourceName: String
    public let elapsedMilliseconds: Int?
    public init(novel: OnlineNovel, sourceName: String, elapsedMilliseconds: Int? = nil) {
        self.novel = novel; self.sourceName = sourceName; self.elapsedMilliseconds = elapsedMilliseconds
    }
    // A book URL can occur in several sources; retain each source's rules.
    public var id: String { SourceSearchState.key(sourceID: novel.sourceID, novelID: novel.id) }
}

public struct SourceSearchFailure: Identifiable, Sendable {
    public let id: String
    public let sourceName: String
    public let message: String
}

public struct SourceSearchState: Sendable {
    public static let maximumResults = 5000
    public private(set) var hits: [SourceSearchHit] = []
    public private(set) var failures: [String: SourceSearchFailure] = [:]
    public private(set) var nextPages: [String: Int] = [:]
    public private(set) var exhausted: Set<String> = []
    private var seen: Set<String> = []
    public var limitReached: Bool { hits.count >= Self.maximumResults }
    public init() {}

    static func key(sourceID: String, novelID: String) -> String {
        // Length-prefixing avoids collisions even when a URL contains separators.
        "\(sourceID.utf8.count):\(sourceID)\(novelID)"
    }

    public mutating func receive(_ outcome: SourceSearchOutcome) {
        if let message = outcome.failure {
            failures[outcome.sourceID] = SourceSearchFailure(id: outcome.sourceID, sourceName: outcome.sourceName, message: message)
            return // Retry the failed page; do not silently skip ahead.
        }
        failures.removeValue(forKey: outcome.sourceID)
        let before = hits.count
        for novel in outcome.novels where !limitReached {
            let hit = SourceSearchHit(novel: novel, sourceName: outcome.sourceName, elapsedMilliseconds: outcome.elapsedMilliseconds)
            if seen.insert(hit.id).inserted { hits.append(hit) }
        }
        if hits.count == before { exhausted.insert(outcome.sourceID) }
        else { nextPages[outcome.sourceID] = outcome.page + 1 }
    }
}

public enum SourceSearch {
    /// Delivers each completed source immediately. A failed source doesn't discard
    /// successful sources. Returning false from onResult cancels pending work.
    public static func run(requests: [SourceSearchRequest], concurrency: Int = 4,
                           timeoutSeconds: Double = 30,
                           search: @escaping @Sendable (BookSource, Int) async throws -> [OnlineNovel],
                           onResult: @escaping @Sendable (SourceSearchOutcome) async -> Bool) async throws {
        guard requests.count <= 5000, requests.allSatisfy({ (1...10000).contains($0.page) }) else {
            throw SourceError.message("搜索书源数量或分页范围超过限制。")
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        let jobs = requests.filter { seen.insert($0.source.id).inserted }
        let worker: @Sendable (SourceSearchRequest) async throws -> SourceSearchOutcome = { job in
            try Task.checkCancellation()
            let start = ContinuousClock.now
            do {
                let novels = try await withThrowingTaskGroup(of: [OnlineNovel].self) { attempts in
                    attempts.addTask { try await search(job.source, job.page) }
                    attempts.addTask {
                        let seconds = timeoutSeconds.isFinite ? min(120, max(0.01, timeoutSeconds)) : 30
                        try await Task.sleep(for: .seconds(seconds))
                        throw SourceError.message("书源搜索超时，可单独重试或在搜索设置延长等待时间。")
                    }
                    defer { attempts.cancelAll() }
                    return try await attempts.next() ?? []
                }
                try Task.checkCancellation()
                let duration = start.duration(to: .now).components
                let elapsed = max(0, Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000))
                return SourceSearchOutcome(sourceID: job.source.id, sourceName: job.source.bookSourceName, page: job.page, novels: novels, elapsedMilliseconds: elapsed)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                return SourceSearchOutcome(sourceID: job.source.id, sourceName: job.source.bookSourceName, page: job.page, novels: [], failure: error.localizedDescription)
            }
        }
        try await withThrowingTaskGroup(of: SourceSearchOutcome.self) { group in
            var next = 0
            for _ in 0..<min(jobs.count, min(8, max(1, concurrency))) {
                let job = jobs[next]; next += 1
                group.addTask { try await worker(job) }
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                guard await onResult(outcome) else { group.cancelAll(); return }
                if next < jobs.count {
                    let job = jobs[next]; next += 1
                    group.addTask { try await worker(job) }
                }
            }
        }
    }
}
