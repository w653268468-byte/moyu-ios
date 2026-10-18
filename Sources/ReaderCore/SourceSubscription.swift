import Foundation

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
