import Foundation

public struct SourceValidationProgress: Sendable {
    public var stage: String
    public var keyword: String
    public var title: String? = nil
    public var chapters: Int? = nil
    public var chapterIndex: Int? = nil
    public var chapterTitle: String? = nil
    public var characters: Int? = nil
}
public struct SourceValidationResult: Codable, Sendable {
    public var keyword: String
    public var title: String
    public var chapters: Int
    public var chapterIndex: Int
    public var chapterTitle: String
    public var characters: Int
}

public enum SourceValidator {
    public static let minimumCharacters = 200
    public static func validate(_ source: BookSource, client: SourceClient,
                                progress: (@Sendable (SourceValidationProgress) async -> Void)? = nil) async throws -> SourceValidationResult {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: SourceValidationResult.self) { group in
            group.addTask { try await run(source, client: client, progress: progress) }
            group.addTask { try await Task.sleep(for: .seconds(45)); throw SourceError.message("单源完整链路检查超过 45 秒") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func run(_ source: BookSource, client: SourceClient,
                            progress: (@Sendable (SourceValidationProgress) async -> Void)?) async throws -> SourceValidationResult {
        let original = source.originalJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let suggested = (original?["ruleSearch"] as? [String: Any])?["checkKeyWord"] as? String
        var keywords: [String] = []
        for value in [suggested, "三国演义", "凡人修仙传"].compactMap({ $0 }) where !value.isEmpty && value.count <= 32 && !keywords.contains(value) { keywords.append(value) }
        var books: [OnlineNovel] = [], keyword = keywords[0]
        for candidate in keywords {
            keyword = candidate
            await progress?(SourceValidationProgress(stage: "search", keyword: keyword))
            books = try await client.search(keyword, source: source)
            if !books.isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let exact = books.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == keyword }
        guard let book = exact ?? books.first else { throw SourceError.message("测试关键词均没有解析到书籍") }
        await progress?(SourceValidationProgress(stage: "catalog", keyword: keyword, title: book.title))
        try await Task.sleep(for: .milliseconds(500))
        let novel = try await client.catalog(book, source: source)
        guard !novel.chapters.isEmpty else { throw SourceError.message("目录为空") }
        let opening = Array(novel.chapters.prefix(10).enumerated())
        // Prefer numbered story chapters to author notices and character summaries.
        // Reading itself still exposes every catalog entry unchanged.
        let numbered = opening.filter { $0.element.title.range(of: #"(?i)^(?:第[0-9０-９一二三四五六七八九十百千万零〇两壹贰叁肆伍陆柒捌玖拾佰仟]+[章回节]|chapter\s*[0-9]+)"#, options: .regularExpression) != nil }
        let narrative = opening.filter { $0.element.title.range(of: #"^(?:感谢|感言|公告|前言|序言|后记|上架|请假|致读者|作品相关|人物资料|设定|更新说明)|(?:年龄.*法宝|路线总结|求月票|求推荐票)"#, options: .regularExpression) == nil }
        let candidates = (numbered.isEmpty ? narrative : numbered).prefix(3)
        guard !candidates.isEmpty else { throw SourceError.message("目录开头仅有前言、通知或资料，尚未完成正文验证") }
        for (index, chapter) in candidates {
            await progress?(SourceValidationProgress(stage: "content", keyword: keyword, title: novel.title, chapters: novel.chapters.count, chapterIndex: index, chapterTitle: chapter.title))
            try await Task.sleep(for: .milliseconds(500))
            let text = try await client.chapter(chapter, source: source)
            await progress?(SourceValidationProgress(stage: "content", keyword: keyword, title: novel.title, chapters: novel.chapters.count, chapterIndex: index, chapterTitle: chapter.title, characters: text.count))
            if text.count >= minimumCharacters { return SourceValidationResult(keyword: keyword, title: novel.title, chapters: novel.chapters.count, chapterIndex: index, chapterTitle: chapter.title, characters: text.count) }
        }
        throw SourceError.message("检查三个候选章节的正文不足 \(minimumCharacters) 字，暂不认定链路可用")
    }
}
