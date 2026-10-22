import Foundation

public struct SourceRule: Codable, Equatable, Sendable {
    public var initialization: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var bookUrl: String?
    public var intro: String?
    public var tocUrl: String?
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    public var content: String?
    public var nextTocUrl: String?
    public var nextContentUrl: String?
    public var coverUrl: String?
    public var wordCount: String?
    public var kind: String?
    public var lastChapter: String?
    public var replaceRegex: String?

    enum CodingKeys: String, CodingKey {
        case initialization = "init"
        case bookList, name, author, bookUrl, intro, tocUrl, chapterList, chapterName, chapterUrl
        case content, nextTocUrl, nextContentUrl
        case coverUrl, wordCount, kind, lastChapter, replaceRegex
    }

    var values: [String] {
        [initialization, bookList, name, author, bookUrl, intro, tocUrl, chapterList, chapterName,
         chapterUrl, content, nextTocUrl, nextContentUrl, coverUrl, wordCount, kind, lastChapter, replaceRegex].compactMap { $0 }
    }
}

public struct BookSource: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bookSourceUrl }
    public var bookSourceName: String
    public var bookSourceUrl: String
    public var bookSourceGroup: String?
    public var enabled: Bool?
    public var originalJSON: String?
    public var searchUrl: String?
    public var exploreUrl: String?
    public var enabledExplore: Bool?
    public var header: String?
    public var jsLib: String?
    public var ruleSearch: SourceRule?
    public var ruleExplore: SourceRule?
    public var ruleBookInfo: SourceRule?
    public var ruleToc: SourceRule?
    public var ruleContent: SourceRule?

    public var searchIncompatibility: String? {
        guard let base = URL(string: bookSourceUrl), ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil else { return "书源网站地址无效" }
        guard let searchUrl, !searchUrl.isEmpty, let rule = ruleSearch,
              !(rule.bookList ?? "").isEmpty, !(rule.name ?? "").isEmpty, !(rule.bookUrl ?? "").isEmpty else { return "缺少搜索规则" }
        for value in [rule.bookList, rule.name, rule.bookUrl, rule.author, rule.intro].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if !HTMLRule.isSupported(value) && !JSONRule.isSupported(value) && !ScriptRule.isSupported(value) && !RuleComposition.isSupported(value) { return "搜索规则暂不支持：\(value.prefix(65))" }
        }
        if !ScriptTemplate.needsScript(searchUrl) {
            do { _ = try SourceRequest.make(searchUrl, query: "测试", base: base) } catch { return error.localizedDescription }
        }
        return nil
    }

    public var incompatibility: String? {
        guard let url = URL(string: bookSourceUrl), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return "书源基础地址不是有效的 HTTP/HTTPS 网址"
        }
        let rules = [ruleSearch?.bookList, ruleSearch?.name, ruleSearch?.bookUrl,
                     ruleBookInfo?.initialization, ruleBookInfo?.tocUrl,
                     ruleToc?.chapterList, ruleToc?.chapterName, ruleToc?.chapterUrl, ruleToc?.nextTocUrl,
                     ruleContent?.content, ruleContent?.nextContentUrl].compactMap { $0 }.filter { !$0.isEmpty }
        if let unsupported = rules.first(where: { !HTMLRule.isSupported($0) && !JSONRule.isSupported($0) && !ScriptRule.isSupported($0) && !RuleComposition.isSupported($0) }) {
            return "含暂不支持的规则：\(String(unsupported.prefix(65)))"
        }
        if let searchUrl, !ScriptTemplate.needsScript(searchUrl), let base = URL(string: bookSourceUrl) {
            do { _ = try SourceRequest.make(searchUrl, query: "测试", base: base) }
            catch { return error.localizedDescription }
        }
        if let header, !header.isEmpty, !ScriptTemplate.needsScript(header) {
            do { _ = try SourceHeaders.parse(header) } catch { return error.localizedDescription }
        }
        guard let toc = ruleToc, !(toc.chapterList ?? "").isEmpty,
              !(toc.chapterName ?? "").isEmpty, !(toc.chapterUrl ?? "").isEmpty,
              !(ruleContent?.content ?? "").isEmpty else {
            return "缺少章节列表、章节名、章节地址或正文规则"
        }
        return nil
    }
}

public struct SourceImport: Sendable {
    public static let maximumBytes = 20 * 1024 * 1024
    public var sources: [BookSource]
    public var failures: [String]
    public var diagnostics: [String] = []

    public static func parse(_ data: Data) throws -> SourceImport {
        guard data.count <= maximumBytes else { throw SourceError.message("书源文件超过 20 MB。") }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch {
            let text = String(data: data.prefix(1024), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.hasPrefix("<") { throw SourceError.message("收到的是网页，不是 JSON 书源。可能是短链接跳转页、登录页或网站验证页，请使用实际的 JSON 地址或文件。") }
            if text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("legado://") {
                throw SourceError.message("内容是书源网址，不是 JSON 文件，请通过网址获取书源。")
            }
            throw SourceError.message("JSON 格式不正确，请复制完整的书源对象或数组，保留开头和结尾的括号。")
        }
        let entries: [Any]
        if let array = value as? [Any] { entries = array }
        else if value is [String: Any] { entries = [value] }
        else { throw SourceError.message("请提供阅读 3.x JSON 书源对象或数组。") }
        guard entries.count <= 5000 else { throw SourceError.message("一次最多导入 5000 个书源，请拆分后重试。") }
        var sources: [BookSource] = []
        var failures: [String] = []
        for (index, entry) in entries.enumerated() {
            do {
                let json = try JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed])
                var source = try JSONDecoder().decode(BookSource.self, from: json)
                source.originalJSON = String(data: json, encoding: .utf8)
                if let existing = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[existing] = source
                    failures.append("第 \(index + 1) 项地址重复，预览保留最后一份规则。")
                } else { sources.append(source) }
            } catch { failures.append("第 \(index + 1) 项格式无法解析：\(error.localizedDescription)") }
        }
        return SourceImport(sources: sources, failures: failures)
    }

    public static func export(_ sources: [BookSource]) throws -> Data {
        let entries = try sources.map { source -> [String: Any] in
            var original = source.originalJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
            for (key, value) in known where key != "originalJSON" { original[key] = value }
            original.removeValue(forKey: "originalJSON")
            return original
        }
        return try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
    }
}

public enum SourceError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct OnlineChapter: Codable, Identifiable, Equatable, Sendable {
    public var id: String { requestTemplate ?? url.absoluteString }
    public var title: String
    public var url: URL
    public var ruleVariables: [String: String]?
    public var requestTemplate: String?
    public var nextChapterURL: URL? = nil
}

public struct OnlineNovel: Codable, Identifiable, Equatable, Sendable {
    public var id: String { shelfID ?? requestTemplate ?? url.absoluteString }
    public var shelfID: String?
    public var readingMarks: [OnlineReadingMark]?
    public var coverURL: URL?
    public var kind: String?
    public var wordCountLabel: String?
    public var lastChapter: String?
    public var title: String
    public var author: String
    public var intro: String
    public var url: URL
    public var sourceID: String
    public var chapters: [OnlineChapter] = []
    public var chapterIndex = 0
    public var lastReadAt: Date?
    public var textOffset: Int?
    public var scrollFraction: Double?
    public var ruleVariables: [String: String]?
    public var requestTemplate: String?

    public init(title: String, author: String = "", intro: String = "", url: URL, sourceID: String) {
        self.title = title
        self.author = author
        self.intro = intro
        self.url = url
        self.sourceID = sourceID
    }

    /// Keep the same chapter after additions, removals or a reordered catalog.
    public func preservingReadingPosition(from current: OnlineNovel) -> OnlineNovel {
        var result = self
        let oldChapter = current.chapters.indices.contains(current.chapterIndex) ? current.chapters[current.chapterIndex] : nil
        if let oldChapter, let destination = chapters.firstIndex(where: { $0.id == oldChapter.id }) {
            result.chapterIndex = destination
            result.textOffset = current.textOffset; result.scrollFraction = current.scrollFraction
        } else {
            result.chapterIndex = min(max(0, current.chapterIndex), max(0, chapters.count - 1))
            result.textOffset = 0; result.scrollFraction = 0
        }
        result.readingMarks = current.readingMarks; result.lastReadAt = current.lastReadAt
        return result
    }
}
