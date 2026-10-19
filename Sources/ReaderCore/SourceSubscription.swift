import Foundation

public enum SourceImportInput: Sendable {
    case json(Data)
    case links([URL])

    public static func detect(_ text: String) throws -> SourceImportInput {
        guard text.utf8.count <= SourceImport.maximumBytes else { throw SourceError.message("书源内容超过 20 MB。") }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !input.isEmpty else { throw SourceError.message("请粘贴书源网址或 JSON 内容。") }
        // Detect JSON before counting lines: a formatted source is not a list of URLs.
        if input.hasPrefix("[") || input.hasPrefix("{") { return .json(Data(input.utf8)) }
        let lines = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count <= 20 else { throw SourceError.message("一次最多获取 20 个网址；JSON 书源内容不按行数计算，请粘贴完整 JSON。") }
        let urls = try lines.map { line -> URL in
            var raw = line
            if let components = URLComponents(string: raw), components.scheme?.lowercased() == "legado" {
                guard let embedded = components.queryItems?.first(where: { $0.name == "src" })?.value else {
                    throw SourceError.message("阅读分享链接缺少 src 书源地址。")
                }
                raw = embedded
            }
            guard let components = URLComponents(string: raw), ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
                throw SourceError.message("请输入完整的 HTTP/HTTPS 网址，或以 [ 或 { 开头的 JSON 书源内容。")
            }
            return try SourceClient.resolve(raw, base: URL(string: "https://example.com")!)
        }
        return .links(urls)
    }
}

public enum SourceSubscription {
    public static func normalize(_ url: URL) throws -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 5, parts[2] == "blob" {
            return try SourceClient.resolve("https://raw.githubusercontent.com/" + ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/"), base: url)
        }
        if parts.prefix(2).map({ $0.lowercased() }) == ["52liulian", "yuanc"], parts.count <= 2 {
            return URL(string: "https://raw.githubusercontent.com/52liulian/yuanc/main/data/legado/books.json")!
        }
        return url
    }

    /// Only explicitly linked JSON indexes are followed; no scripts, arbitrary page scraping or recursive crawl.
    public static func links(in data: Data, base: URL) throws -> [URL]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let array = value as? [[String: Any]] { entries = array }
        else { return nil }
        guard !entries.isEmpty, entries.allSatisfy({ $0["bookSourceUrl"] == nil && $0["link"] is String }) else { return nil }
        guard entries.count <= 20 else { throw SourceError.message("书源索引包含超过 20 个订阅链接，请分批导入实际 JSON 链接。") }
        return try entries.map { try SourceClient.resolve($0["link"] as! String, base: base) }
    }
}
