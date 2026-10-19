import SwiftUI
import CryptoKit

@MainActor
final class OnlineStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = []
    @Published private(set) var novels: [OnlineNovel] = []
    @Published var errorMessage: String?
    @Published private(set) var locked = false
    let client = SourceClient(cookieProvider: { url in await BrowserSessions.cookies(for: url) }, webRenderer: { request, cookies in try await SourceWebRenderer.render(request, cookies: cookies) })
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var backupURL: URL { directory.appendingPathComponent("index.backup.json") }

    private struct Index: Codable { var sources: [BookSource]; var novels: [OnlineNovel] }

    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let data: Data
                do {
                    let original = try Data(contentsOf: indexURL)
                    _ = try JSONDecoder().decode(Index.self, from: original)
                    data = original
                } catch {
                    data = try Data(contentsOf: backupURL)
                    _ = try JSONDecoder().decode(Index.self, from: data)
                    try data.write(to: indexURL, options: .atomic)
                    errorMessage = "在线书架已从备份恢复。"
                }
                let index = try JSONDecoder().decode(Index.self, from: data)
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
        let data = try JSONEncoder().encode(Index(sources: sources, novels: novels))
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try Data(contentsOf: indexURL).write(to: backupURL, options: .atomic)
        }
        try data.write(to: indexURL, options: .atomic)
    }

    func addSources(_ incoming: [BookSource]) throws {
        let old = sources
        for source in incoming {
            if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
            else { sources.append(source) }
        }
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
        for index in sources.indices where ids.contains(sources[index].id) { sources[index].enabled = enabled }
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
        var updated = novels.first { $0.id == novel.id } ?? novel
        if textOffset != nil { updated.scrollFraction = scrollFraction }
        else if updated.chapterIndex != index { updated.scrollFraction = nil }
        updated.textOffset = textOffset ?? (updated.chapterIndex == index ? updated.textOffset : 0)
        updated.chapterIndex = index
        updated.lastReadAt = Date()
        do { try keep(updated) } catch { errorMessage = error.localizedDescription }
    }

    func commitReplacement(_ original: OnlineNovel, replacement: SourceSwitchResult) throws {
        guard !locked, replacement.novel.chapters.indices.contains(replacement.novel.chapterIndex) else { throw SourceError.message("替代书源或章节无效。") }
        var updated = replacement.novel
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
