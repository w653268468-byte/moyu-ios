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
    let client = SourceClient(cookieProvider: { url in await BrowserSessions.cookies(for: url) }, webRenderer: { request, cookies in try await SourceWebRenderer.render(request, cookies: cookies) }, verificationHandler: { input in try await SourceVerificationUI.run(input) })
    private let directory: URL
    private let writer: DeferredSnapshotWriter
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var backupURL: URL { directory.appendingPathComponent("index.backup.json") }

    private struct Index: Codable, Sendable { var sources: [BookSource]; var novels: [OnlineNovel] }

    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline", isDirectory: true)) {
        self.directory = directory
        writer = DeferredSnapshotWriter(destination: directory.appendingPathComponent("index.json"), backup: directory.appendingPathComponent("index.backup.json"))
        reload()
    }

    func reload() {
        writer.discardPendingAndWait()
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
    func flushProgress() throws { try writer.flush() }
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

    func remove(_ novel: OnlineNovel) {
        let old = novels
        novels.removeAll { $0.id == novel.id && $0.sourceID == novel.sourceID }
        do { try save() } catch { novels = old; errorMessage = error.localizedDescription }
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

    func clearCache() {
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "txt" { try FileManager.default.removeItem(at: url) }
        } catch { errorMessage = "清理缓存失败：\(error.localizedDescription)" }
    }
}
