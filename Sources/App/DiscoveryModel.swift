import SwiftUI

struct DiscoverySnapshot: Codable, Sendable {
    var signature: String
    var day: String
    var updatedAt: Date
    var categories: [ExploreCategory]
    var books: [OnlineNovel]
}

actor DiscoveryCache {
    private let file: URL
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) { file = directory.appendingPathComponent("discovery.json") }
    func read(signature: String) -> DiscoverySnapshot? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(DiscoverySnapshot.self, from: data),
              snapshot.signature == signature, snapshot.categories.count <= 500, snapshot.books.count <= 150 else { return nil }
        return snapshot
    }
    func save(_ snapshot: DiscoverySnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 2 * 1024 * 1024 else { throw SourceError.message("推荐缓存超过大小限制。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

enum DiscoveryRequest {
    static func books(_ category: ExploreCategory, page: Int, source: BookSource, client: SourceClient) async throws -> [OnlineNovel] {
        try await withThrowingTaskGroup(of: [OnlineNovel].self) { group in
            group.addTask { try await client.explore(category, page: page, source: source) }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw SourceError.message("发现列表响应超时，请重试或切换书源。") }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }
}

@MainActor final class DiscoveryModel: ObservableObject {
    @Published private(set) var categories: [ExploreCategory] = []
    @Published private(set) var pool: [OnlineNovel] = []
    @Published private(set) var loading = false
    @Published private(set) var failures: [String] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var day = DiscoveryCatalog.dayKey()
    @Published var batch = 0
    private let cache: DiscoveryCache
    private var signature = ""
    private var generation = UUID()
    private var request: Task<Void, Never>?
    init(cache: DiscoveryCache = DiscoveryCache()) { self.cache = cache }
    var books: [OnlineNovel] { DiscoveryCatalog.dailyBooks(pool, day: day, batch: batch) }
    var sections: [DiscoveryCategory] { DiscoveryCatalog.sections(categories) }
    func cancel() { request?.cancel(); request = nil; generation = UUID(); loading = false }
    func load(source: BookSource, client: SourceClient, force: Bool = false) async {
        cancel(); let token = generation, fingerprint = SourceHealthLedger.signature(source)
        if signature != fingerprint { categories = []; pool = []; updatedAt = nil; batch = 0; signature = fingerprint }
        loading = true; failures = []
        let job = Task { @MainActor in
            defer { if generation == token { loading = false; request = nil } }
            let today = DiscoveryCatalog.dayKey()
            if let saved = await cache.read(signature: fingerprint) {
                guard generation == token, !Task.isCancelled else { return }
                categories = saved.categories; pool = saved.books; day = saved.day; updatedAt = saved.updatedAt
                if !force && saved.day == today && Date().timeIntervalSince(saved.updatedAt) < 1800 && !saved.books.isEmpty { return }
            }
            do {
                let categoryClient = await client.isolatedWorker(reloadIgnoringCache: true)
                let found = try await categoryClient.categories(source: source)
                try Task.checkCancellation(); guard generation == token else { return }
                categories = found
                var fresh: [OnlineNovel] = [], errors: [String] = []
                for category in DiscoveryCatalog.dailyCategories(found, day: today) {
                    try Task.checkCancellation()
                    do {
                        // A separate context retains this list's JavaScript state;
                        // recompute category setup before evaluating the list URL.
                        let worker = await client.isolatedWorker(reloadIgnoringCache: true)
                        let refreshed = try await worker.categories(source: source)
                        guard let selected = DiscoveryCatalog.sections(found).first(where: { $0.id == category.id }) else { continue }
                        let activeCategory = try DiscoveryCatalog.refreshed(selected, in: refreshed)
                        let books = try await DiscoveryRequest.books(activeCategory, page: 1, source: source, client: worker)
                        try Task.checkCancellation(); guard generation == token else { return }
                        for var book in books.prefix(50) where !fresh.contains(where: { $0.id == book.id }) {
                            book.intro = String(book.intro.prefix(1000)); fresh.append(book)
                        }
                        if !fresh.isEmpty { pool = fresh; day = today; batch = 0 }
                    } catch { try Task.checkCancellation(); errors.append(category.title + "：" + error.localizedDescription) }
                }
                guard generation == token else { return }
                failures = errors
                if fresh.isEmpty && !errors.isEmpty { return } // Keep the last usable daily cache on a network failure.
                pool = fresh; day = today; batch = 0; updatedAt = Date()
                do { try await cache.save(DiscoverySnapshot(signature: fingerprint, day: today, updatedAt: updatedAt!, categories: found, books: fresh)) }
                catch { if generation == token { failures.append("缓存保存失败：" + error.localizedDescription) } }
            } catch { if generation == token && !Task.isCancelled { failures = [error.localizedDescription] } }
        }
        request = job
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }
}

@MainActor final class DiscoveryFeedModel: ObservableObject {
    @Published private(set) var books: [OnlineNovel] = []
    @Published private(set) var page = 0
    @Published private(set) var loading = false
    @Published private(set) var exhausted = false
    @Published private(set) var failure: String?
    private var worker: SourceClient?
    private var category: ExploreCategory?
    private var retryRefresh = false
    private var generation = UUID()
    private var request: Task<Void, Never>?
    func cancel() { request?.cancel(); request = nil; generation = UUID(); loading = false }
    func load(source: BookSource, entry: DiscoveryCategory, client: SourceClient, refresh: Bool = false) async {
        let resetting = refresh || retryRefresh
        guard !loading, resetting || !exhausted else { return }
        cancel(); let token = generation, next = resetting ? 1 : page + 1
        if resetting { retryRefresh = true }
        loading = true; failure = nil
        let job = Task { @MainActor in
            defer { if generation == token { loading = false; request = nil } }
            do {
                if worker == nil || resetting {
                    let newWorker = await client.isolatedWorker(reloadIgnoringCache: true)
                    let refreshed = try await newWorker.categories(source: source)
                    let activeCategory = try DiscoveryCatalog.refreshed(entry, in: refreshed)
                    try Task.checkCancellation(); guard generation == token else { return }; worker = newWorker; category = activeCategory
                }
                guard let worker, let category else { return }
                let found = try await DiscoveryRequest.books(category, page: next, source: source, client: worker)
                try Task.checkCancellation(); guard generation == token else { return }
                var result = resetting ? [] : books
                var seen = Set(result.map(\.id)); let before = result.count
                result += found.filter { seen.insert($0.id).inserted }.prefix(max(0, 1000 - result.count))
                books = result; page = next; exhausted = result.count == before || result.count >= 1000; retryRefresh = false
            } catch { if generation == token && !Task.isCancelled { failure = error.localizedDescription } }
        }
        request = job
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }
}
