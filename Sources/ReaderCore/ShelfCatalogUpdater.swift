import Foundation

public struct ShelfCatalogOutcome: Sendable {
    public let original: OnlineNovel
    public let catalog: OnlineNovel?
    public let failure: String?
}

public enum ShelfCatalogUpdater {
    /// Each novel owns its script worker. A failure never cancels other books.
    public static func run(books: [OnlineNovel], sources: [BookSource], client: SourceClient,
                           concurrency: Int = 2, timeout: Double = 45,
                           onResult: @escaping @Sendable (ShelfCatalogOutcome) async -> Void) async throws {
        let lookup = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let worker: @Sendable (OnlineNovel) async throws -> ShelfCatalogOutcome = { book in
            try Task.checkCancellation()
            guard let source = lookup[book.sourceID] else {
                return ShelfCatalogOutcome(original: book, catalog: nil, failure: "原书源已删除，请重新导入书源或换源。")
            }
            do {
                let isolated = await client.isolatedWorker()
                let result = try await withThrowingTaskGroup(of: OnlineNovel.self) { attempts in
                    attempts.addTask { try await isolated.catalog(book, source: source) }
                    attempts.addTask {
                        try await Task.sleep(for: .seconds(timeout.isFinite ? min(180, max(1, timeout)) : 45))
                        throw SourceError.message("目录更新超时，可稍后重试。")
                    }
                    defer { attempts.cancelAll() }
                    guard let first = try await attempts.next() else { throw CancellationError() }
                    return first
                }
                try Task.checkCancellation()
                return ShelfCatalogOutcome(original: book, catalog: result, failure: nil)
            } catch {
                try Task.checkCancellation()
                return ShelfCatalogOutcome(original: book, catalog: nil, failure: error.localizedDescription)
            }
        }
        try await withThrowingTaskGroup(of: ShelfCatalogOutcome.self) { tasks in
            var iterator = books.makeIterator()
            for _ in 0..<min(max(1, min(4, concurrency)), books.count) {
                if let book = iterator.next() { tasks.addTask { try await worker(book) } }
            }
            while let result = try await tasks.next() {
                try Task.checkCancellation()
                await onResult(result)
                if let book = iterator.next() { tasks.addTask { try await worker(book) } }
            }
        }
    }
}
