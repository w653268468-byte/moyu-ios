import Foundation

public struct ExploreCategory: Codable, Identifiable, Equatable, Sendable {
    public var id: String { title + "|" + url }
    public var title: String
    public var url: String
    public var isHeading: Bool { url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public static func parse(_ text: String) throws -> [ExploreCategory] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw SourceError.message("发现分类配置超过 2 MB。") }
        var rows: [ExploreCategory] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["), (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) == nil { throw SourceError.message("发现分类不是有效的 JSON 数组。") }
        if let data = text.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in values {
                guard let title = (item["title"] ?? item["name"]) as? String else { continue }
                rows.append(ExploreCategory(title: title, url: item["url"] as? String ?? ""))
            }
        } else {
            for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let split = line.range(of: "::") {
                    rows.append(ExploreCategory(title: String(line[..<split.lowerBound]), url: String(line[split.upperBound...])))
                } else { rows.append(ExploreCategory(title: line, url: "")) }
            }
        }
        guard rows.count <= 500 else { throw SourceError.message("发现分类超过 500 项。") }
        var seen = Set<String>()
        return rows.map { ExploreCategory(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.title.isEmpty && seen.insert($0.id).inserted }
    }
}
