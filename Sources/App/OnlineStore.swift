import SwiftUI
import CryptoKit

@MainActor
final class OnlineStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = [] { didSet { refreshDiagnostics() } }
    @Published private(set) var sourceDiagnostics: [String: SourceDiagnostics] = [:]
    @Published private(set) var checkingRules = false
    private var diagnosticsTask: Task<Void, Never>?
    @Published private(set) var novels: [OnlineNovel] = []
    @Published var errorMessage: String?
    @Published private(set) var locked = false
    let client: SourceClient
    private let directory: URL
    private let writer: DeferredSnapshotWriter
    private let downloadWriter: DeferredSnapshotWriter
    @Published private(set) var downloads: [String: OfflineDownloadState] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadRuns: [String: UUID] = [:]
    private var cacheRevision = UUID()
    private var downloadsURL: URL { directory.appendingPathComponent("downloads.json") }
    func downloadKey(_ book: OnlineNovel) -> String { book.sourceID + "|" + book.id }
    func downloadState(_ book: OnlineNovel) -> OfflineDownloadState? { downloads[downloadKey(book)] }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var backupURL: URL { directory.appendingPathComponent("index.backup.json") }

    private struct Index: Codable, Sendable { var sources: [BookSource]; var novels: [OnlineNovel] }

    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline", isDirectory: true), client: SourceClient? = nil) {
        self.client = client ?? SourceClient(cookieProvider: { url in await BrowserSessions.cookies(for: url) }, webRenderer: { request, cookies in try await SourceWebRenderer.render(request, cookies: cookies) }, verificationHandler: { input in try await SourceVerificationUI.run(input) })
        self.directory = directory
        writer = DeferredSnapshotWriter(destination: directory.appendingPathComponent("index.json"), backup: directory.appendingPathComponent("index.backup.json"))
        downloadWriter = DeferredSnapshotWriter(destination: directory.appendingPathComponent("downloads.json"), backup: directory.appendingPathComponent("downloads.backup.json"))
        reload()
    }

    func reload() {
        cacheRevision = UUID()
        pauseAllDownloads()
        writer.discardPendingAndWait()
        downloadWriter.discardPendingAndWait()
        downloads = (try? JSONDecoder().decode([String: OfflineDownloadState].self, from: Data(contentsOf: downloadsURL))) ?? [:]
        for key in downloads.keys where downloads[key]?.phase == .downloading { downloads[key]?.phase = .paused }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index: Index
                do {
                    index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                } catch {
                    let data = try Data(contentsOf: backupURL)
                    index = try JSONDecoder().decode(Index.self, from: data)
                    try data.write(to: indexURL, options: .atomic)
                    errorMessage = "在线书架已从备份恢复。"
                }
                sources = index.sources
                novels = index.novels
            } else {
                sources = []
                novels = []
            }
            locked = false
        } catch { locked = true; errorMessage = "在线书架读取失败：\(error.localizedDescription)。已暂停写入，请先备份后重试。" }
    }

    private func save() throws {
        guard !locked else { throw SourceError.message("存储暂不可用，请先重新读取书架。") }
        let snapshot = Index(sources: sources, novels: novels)
        try writer.writeNow { try JSONEncoder().encode(snapshot) }
    }
    func flushProgress() throws { try writer.flush(); try downloadWriter.flush() }
    func sourceReason(_ source: BookSource) -> String? { sourceDiagnostics[source.id]?.full }
    func searchReason(_ source: BookSource) -> String? { sourceDiagnostics[source.id]?.search }
    private func refreshDiagnostics() {
        diagnosticsTask?.cancel()
        sourceDiagnostics = [:]; checkingRules = !sources.isEmpty
        let snapshot = sources
        diagnosticsTask = Task { [weak self] in
            do {
                let result = try await SourceDiagnostics.analyze(snapshot)
                try Task.checkCancellation()
                self?.sourceDiagnostics = result; self?.checkingRules = false
            } catch { if !Task.isCancelled { self?.checkingRules = false } }
        }
    }

    func addSources(_ incoming: [BookSource]) throws {
        let old = sources
        var merged = sources
        var positions: [String: Int] = [:]
        for (index, source) in merged.enumerated() { positions[source.id] = index }
        for source in incoming {
            if let index = positions[source.id] { merged[index] = source }
            else { positions[source.id] = merged.count; merged.append(source) }
        }
        sources = merged
        do { try save() } catch { sources = old; throw error }
    }

    func deleteSource(_ source: BookSource) {
        deleteSources([source.id])
    }

    func deleteSources(_ ids: Set<String>) {
        let old = sources
        sources.removeAll { ids.contains($0.id) }
        do { try save() } catch { sources = old; errorMessage = error.localizedDescription }
    }

    func setEnabled(_ ids: Set<String>, enabled: Bool) {
        let old = sources
        var updated = sources
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].enabled = enabled }
        sources = updated
        do { try save() } catch { sources = old; errorMessage = error.localizedDescription }
    }

    func replaceSource(_ oldID: String, with source: BookSource) throws {
        guard source.id == oldID else { throw SourceError.message("编辑时请保留书源基础地址；新网站请通过导入添加。") }
        try addSources([source])
    }

    func keep(_ novel: OnlineNovel) throws {
        let old = novels
        if let index = novels.firstIndex(where: { $0.id == novel.id && $0.sourceID == novel.sourceID }) {
            novels[index] = novel
        } else { novels.insert(novel, at: 0) }
        do { try save() } catch { novels = old; throw error }
    }

    func keepCatalog(_ book: OnlineNovel) throws {
        var saved = book
        if let current = novels.first(where: { $0.id == book.id && $0.sourceID == book.sourceID }) {
            saved.chapterIndex = min(current.chapterIndex, max(0, book.chapters.count - 1))
            saved.textOffset = current.textOffset; saved.scrollFraction = current.scrollFraction
            saved.readingMarks = current.readingMarks; saved.lastReadAt = current.lastReadAt
        }
        try keep(saved)
    }

    func remove(_ novel: OnlineNovel) {
        let old = novels
        novels.removeAll { $0.id == novel.id && $0.sourceID == novel.sourceID }
        do {
            try save()
            pauseDownload(novel)
            downloads.removeValue(forKey: downloadKey(novel)); persistDownloads()
        } catch { novels = old; errorMessage = error.localizedDescription }
    }

    func position(_ novel: OnlineNovel, index: Int, textOffset: Int? = nil, scrollFraction: Double? = nil) {
        guard !locked else { return }
        let existing = novels.firstIndex { $0.id == novel.id && $0.sourceID == novel.sourceID }
        var updated = existing.map { novels[$0] } ?? novel
        let old = updated
        if textOffset != nil { updated.scrollFraction = scrollFraction }
        else if updated.chapterIndex != index { updated.scrollFraction = nil }
        updated.textOffset = textOffset ?? (updated.chapterIndex == index ? updated.textOffset : 0)
        updated.chapterIndex = index
        guard existing == nil || old.chapterIndex != updated.chapterIndex || old.textOffset != updated.textOffset || old.scrollFraction != updated.scrollFraction else { return }
        updated.lastReadAt = Date()
        if let existing { novels[existing] = updated } else { novels.insert(updated, at: 0) }
        let snapshot = Index(sources: sources, novels: novels)
        writer.schedule(encode: { try JSONEncoder().encode(snapshot) }, failure: { [weak self] error in
            Task { @MainActor in self?.errorMessage = "阅读进度保存失败：\(error.localizedDescription)" }
        })
    }

    func saveMark(_ mark: OnlineReadingMark, in novel: OnlineNovel) throws {
        var saved = novels.first { $0.id == novel.id && $0.sourceID == novel.sourceID } ?? novel
        var marks = saved.readingMarks ?? []
        if let index = marks.firstIndex(where: { $0.id == mark.id }) { marks[index] = mark }
        else {
            guard marks.count < 5000 else { throw SourceError.message("本书已有 5000 个书签，请先清理。") }
            marks.insert(mark, at: 0)
        }
        saved.readingMarks = marks; try keep(saved)
    }
    func removeMark(_ id: UUID, in novel: OnlineNovel) throws {
        var saved = novels.first { $0.id == novel.id && $0.sourceID == novel.sourceID } ?? novel
        saved.readingMarks?.removeAll { $0.id == id }; try keep(saved)
    }

    func commitReplacement(_ original: OnlineNovel, replacement: SourceSwitchResult) throws {
        guard !locked, replacement.novel.chapters.indices.contains(replacement.novel.chapterIndex) else { throw SourceError.message("替代书源或章节无效。") }
        var updated = replacement.novel
        updated.readingMarks = novels.first(where: { $0.id == original.id && $0.sourceID == original.sourceID })?.readingMarks ?? original.readingMarks
        updated.shelfID = original.id
        try replacement.text.write(to: cacheURL(updated.chapters[updated.chapterIndex], sourceID: updated.sourceID), atomically: true, encoding: .utf8)
        let before = novels
        if let index = novels.firstIndex(where: { $0.id == original.id && $0.sourceID == original.sourceID }) { novels[index] = updated }
        else { novels.insert(updated, at: 0) }
        do { try save() } catch { novels = before; throw error }
    }

    private func cacheURL(_ chapter: OnlineChapter, sourceID: String) -> URL {
        let hash = SHA256.hash(data: Data((sourceID + "|" + chapter.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).txt")
    }

    func chapter(_ chapter: OnlineChapter, sourceID: String) async throws -> String {
        let cache = cacheURL(chapter, sourceID: sourceID)
        if let text = try? String(contentsOf: cache, encoding: .utf8), !text.isEmpty { return text }
        let text: String
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            throw SourceError.message("对应书源已删除或专用接口已移除。这一章尚未缓存，请重新导入书源。")
        }
        text = try await client.chapter(chapter, source: source)
        try Task.checkCancellation()
        // A failed cache write must be visible; never silently claim offline availability.
        try text.write(to: cache, atomically: true, encoding: .utf8)
        return text
    }

    private func persistDownloads() {
        let snapshot = downloads
        downloadWriter.schedule(encode: { try JSONEncoder().encode(snapshot) }, failure: { [weak self] error in
            Task { @MainActor in self?.errorMessage = "下载记录保存失败：" + error.localizedDescription }
        })
    }
    func pauseDownload(_ book: OnlineNovel) {
        let key = downloadKey(book)
        downloadRuns.removeValue(forKey: key); downloadTasks.removeValue(forKey: key)?.cancel()
        if downloads[key]?.phase == .downloading { downloads[key]?.phase = .paused; downloads[key]?.message = "已暂停，已下载章节保留"; persistDownloads() }
    }
    func pauseAllDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]; downloadRuns = [:]
        for key in Array(downloads.keys) where downloads[key]?.phase == .downloading { downloads[key]?.phase = .paused; downloads[key]?.message = "已暂停，可继续下载" }
        if !downloads.isEmpty { persistDownloads() }
    }
    func refreshDownload(_ book: OnlineNovel) async {
        let revision = cacheRevision
        let key = downloadKey(book)
        guard downloadTasks[key] == nil else { return }
        let paths = book.chapters.map { cacheURL($0, sourceID: book.sourceID) }
        let count = await Task.detached(priority: .utility) {
            paths.reduce(0) { count, path in
                count + (((try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 ? 1 : 0)
            }
        }.value
        guard downloadTasks[key] == nil, !Task.isCancelled, cacheRevision == revision else { return }
        let full = !paths.isEmpty && count == paths.count
        let previous = downloads[key]
        let failed = !full && previous?.phase == .failed
        downloads[key] = OfflineDownloadState(phase: full ? .completed : failed ? .failed : .paused, completed: count, total: paths.count, failed: failed ? (previous?.failed ?? []) : [], message: full ? "全书已下载，可离线阅读" : failed ? (previous?.message ?? "部分章节失败，可重试") : "已下载 \(count)/\(paths.count) 章")
        persistDownloads()
    }
    func startDownload(_ book: OnlineNovel) {
        let key = downloadKey(book)
        guard !locked, downloadTasks[key] == nil else { return }
        guard !book.chapters.isEmpty else { errorMessage = "请先在小说详情获取章节目录，再下载。"; return }
        guard downloadTasks.count < 2 else { errorMessage = "最多同时下载两本书，请先暂停一个任务。"; return }
        do { try keepCatalog(book) } catch { errorMessage = error.localizedDescription; return }
        let token = UUID(); downloadRuns[key] = token
        downloads[key] = OfflineDownloadState(phase: .downloading, total: book.chapters.count, message: "正在检查已下载章节…")
        persistDownloads()
        downloadTasks[key] = Task { [weak self] in
            guard let self else { return }
            let paths = book.chapters.map { self.cacheURL($0, sourceID: book.sourceID) }
            let cached = await Task.detached(priority: .utility) {
                Set(paths.indices.filter { ((try? paths[$0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 })
            }.value
            guard !Task.isCancelled, downloadRuns[key] == token else { return }
            var count = cached.count, failures: [String] = []
            downloads[key]?.completed = count
            for index in book.chapters.indices where !cached.contains(index) {
                let chapter = book.chapters[index]
                guard !Task.isCancelled, downloadRuns[key] == token else { return }
                do {
                    downloads[key]?.message = "正在下载：" + chapter.title
                    _ = try await self.chapter(chapter, sourceID: book.sourceID)
                    try Task.checkCancellation()
                    guard downloadRuns[key] == token else { return }
                    count += 1
                } catch {
                    guard !Task.isCancelled, downloadRuns[key] == token else { return }
                    failures.append(chapter.title)
                    downloads[key]?.message = chapter.title + "：" + error.localizedDescription
                }
                downloads[key]?.completed = count; downloads[key]?.failed = failures
                persistDownloads()
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
            guard downloadRuns[key] == token else { return }
            downloads[key]?.phase = failures.isEmpty ? .completed : .failed
            downloads[key]?.message = failures.isEmpty ? "全书已下载，可离线阅读" : "\(failures.count) 章失败，可重试；已下载章节保留"
            persistDownloads(); downloadRuns.removeValue(forKey: key); downloadTasks.removeValue(forKey: key)
        }
    }

    #if DEBUG
    func prepareOfflineShelfFixture() throws {
        let origin = URL(string: "https://offline-shelf.example")!
        var book = OnlineNovel(title: "离线书架测试", author: "Gavin", url: origin.appendingPathComponent("book"), sourceID: origin.absoluteString)
        book.chapters = (1...3).map { OnlineChapter(title: "第\($0)章 测试", url: origin.appendingPathComponent(String($0))) }
        try keep(book)
        for (index, chapter) in book.chapters.enumerated() {
            try ("第\(index + 1)章 测试\n" + String(repeating: "没有网络也能阅读已经下载的章节。", count: 50)).write(to: cacheURL(chapter, sourceID: book.sourceID), atomically: true, encoding: .utf8)
        }
        downloads[downloadKey(book)] = OfflineDownloadState(phase: .completed, completed: 3, total: 3, message: "全书已下载，可离线阅读")
        persistDownloads(); try flushProgress()
    }
    #endif

    func clearCache() {
        cacheRevision = UUID()
        pauseAllDownloads()
        downloads = [:]; persistDownloads()
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "txt" { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = "清理缓存失败：\(error.localizedDescription)" }
    }
}
