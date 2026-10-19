import Foundation

public enum BookIdentity {
    private static func compact(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
    public static func title(_ text: String) -> String { compact(text.replacingOccurrences(of: "《", with: "").replacingOccurrences(of: "》", with: "")) }
    public static func author(_ text: String) -> String {
        compact(text.replacingOccurrences(of: #"^\s*作者\s*[:：]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+著\s*$"#, with: "", options: .regularExpression))
    }
    public static func matches(_ first: OnlineNovel, _ second: OnlineNovel, allowMissingAuthor: Bool = false) -> Bool {
        guard !title(first.title).isEmpty, title(first.title) == title(second.title) else { return false }
        let a = author(first.author), b = author(second.author)
        if a.isEmpty || b.isEmpty { return allowMissingAuthor }
        return a == b
    }
}

public enum ChapterAlignment {
    private static let numerals = "零〇一二三四五六七八九十百千万两0-9０-９"
    private static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if !text.contains(where: { "十百千万".contains($0) }) {
            let raw = text.compactMap { digits[$0].map(String.init) }.joined()
            return raw.count == text.count ? Int(raw) : nil
        }
        var total = 0, section = 0, digit = 0
        for char in text {
            if let value = digits[char] { digit = value }
            else if char == "万" { total += (section + digit) * 10000; section = 0; digit = 0 }
            else if let unit: Int = ["十":10,"百":100,"千":1000][String(char)] { section += max(1, digit) * unit; digit = 0 }
            else { return nil }
        }
        return total + section + digit
    }
    private static func chapterNumber(_ title: String) -> Int? {
        let text = title.precomposedStringWithCompatibilityMapping
        let patterns = ["第([\(numerals)]+)[章节回]", #"(?i)\bchapter\s+([0-9]+)\b"#]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { continue }
            return number(String(text[range]))
        }
        return nil
    }
    private static func key(_ title: String, stripNumber: Bool) -> String {
        var text = title.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if stripNumber {
            text = text.replacingOccurrences(of: "^(?:正文\\s*)?(?:第[\(numerals)]+[章节回卷部篇集]\\s*[:：、._-]?\\s*)+", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^chapter\s+[0-9]+\s*[:._-]?\s*"#, with: "", options: .regularExpression)
        }
        return text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    public static func find(_ title: String, in chapters: [OnlineChapter]) -> Int? {
        guard !key(title, stripNumber: false).isEmpty else { return nil }
        let exact = chapters.indices.filter { key(chapters[$0].title, stripNumber: false) == key(title, stripNumber: false) }
        if exact.count == 1 { return exact[0] }
        let body = key(title, stripNumber: true)
        if body.count >= 2 {
            let matches = chapters.indices.filter { key(chapters[$0].title, stripNumber: true) == body }
            if matches.count == 1 {
                let target = matches[0]
                if let first = chapterNumber(title), let second = chapterNumber(chapters[target].title), first != second { return nil }
                return target
            }
            if matches.count > 1, let ordinal = chapterNumber(title) {
                let numbered = matches.filter { chapterNumber(chapters[$0].title) == ordinal }
                return numbered.count == 1 ? numbered[0] : nil
            }
        }
        if let ordinal = chapterNumber(title) {
            let numbered = chapters.indices.filter { chapterNumber(chapters[$0].title) == ordinal }
            return numbered.count == 1 ? numbered[0] : nil
        }
        return nil
    }
}

public struct SourceSwitchResult: Sendable {
    public var novel: OnlineNovel
    public var text: String
    public init(novel: OnlineNovel, text: String) { self.novel = novel; self.text = text }
}

public struct SourceSwitcher: Sendable {
    private let client: SourceClient
    public init(client: SourceClient) { self.client = client }
    public func automatic(_ novel: OnlineNovel, chapterIndex: Int, sources: [BookSource], maximumSources: Int = 24,
                          progress: (@Sendable (String) async -> Void)? = nil) async throws -> SourceSwitchResult {
        try await withThrowingTaskGroup(of: SourceSwitchResult.self) { group in
            group.addTask { try await attempt(novel, chapterIndex: chapterIndex, sources: sources, maximumSources: maximumSources, progress: progress) }
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                throw SourceError.message("自动换源已达到 90 秒时限，请手动选择其他书源。")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
    private func attempt(_ novel: OnlineNovel, chapterIndex: Int, sources: [BookSource], maximumSources: Int,
                         progress: (@Sendable (String) async -> Void)?) async throws -> SourceSwitchResult {
        guard novel.chapters.indices.contains(chapterIndex), !BookIdentity.author(novel.author).isEmpty else {
            throw SourceError.message("自动换源需要已知作者及当前章节；信息不足时请手动选择书源和章节。")
        }
        let choices = Array(sources.filter { $0.id != novel.sourceID && $0.enabled != false && $0.incompatibility == nil && !($0.searchUrl ?? "").isEmpty }.prefix(min(50, max(1, maximumSources))))
        guard !choices.isEmpty else { throw SourceError.message("没有其他已启用且规则可识别的书源，请先导入或启用其他书源。") }
        var failures: [String] = []
        for (index, source) in choices.enumerated() {
            try Task.checkCancellation()
            await progress?("尝试换源 \(index + 1)/\(choices.count) · \(source.bookSourceName)")
            do {
                let found = try await client.search(novel.title, source: source)
                let matches = found.filter { BookIdentity.matches(novel, $0) }
                for book in matches.prefix(3) {
                    try Task.checkCancellation()
                    var catalog = try await client.catalog(book, source: source)
                    guard let target = ChapterAlignment.find(novel.chapters[chapterIndex].title, in: catalog.chapters) else { continue }
                    let text = try await client.chapter(catalog.chapters[target], source: source)
                    try Task.checkCancellation()
                    catalog.shelfID = novel.id
                    catalog.chapterIndex = target; catalog.textOffset = 0; catalog.scrollFraction = nil; catalog.lastReadAt = Date()
                    return SourceSwitchResult(novel: catalog, text: text)
                }
                failures.append("\(source.bookSourceName)：没有同书名同作者且章节匹配的可读结果")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append("\(source.bookSourceName)：\(error.localizedDescription)")
            }
        }
        throw SourceError.message("这次未找到可靠的可用替代书源，可手动选择并核对章节。\n" + failures.prefix(5).joined(separator: "\n"))
    }
}
