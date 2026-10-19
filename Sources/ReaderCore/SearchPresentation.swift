import Foundation

public enum BookSearchField: String, CaseIterable, Codable, Sendable {
    case all, title, author
    public var name: String { switch self { case .all: return "书名 / 作者"; case .title: return "只看书名"; case .author: return "只看作者" } }
}

public enum BookSearchSort: String, CaseIterable, Codable, Sendable {
    case relevance, sources, title, speed, arrival
    public var name: String {
        switch self { case .relevance: return "相关度"; case .sources: return "书源数量"; case .title: return "书名"; case .speed: return "搜索速度"; case .arrival: return "返回顺序" }
    }
}

public struct BookSearchGroup: Identifiable, Sendable {
    public let id: String
    public var variants: [SourceSearchHit]
    public var firstIndex: Int
    public var representative: SourceSearchHit { variants[0] }
    public var sourceCount: Int { Set(variants.map { $0.novel.sourceID }).count }
}

public enum BookSearchPresentation {
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
    private static func title(_ value: String) -> String { normalized(value.trimmingCharacters(in: CharacterSet(charactersIn: "《》〈〉「」『』 "))) }
    private static func author(_ value: String) -> String {
        var result = normalized(value)
        if result.hasPrefix("作者:") { result.removeFirst(3) }
        return result
    }
    public static func groups(_ hits: [SourceSearchHit], query: String, field: BookSearchField = .all,
                              exact: Bool = false, merged: Bool = true, sort: BookSearchSort = .relevance) -> [BookSearchGroup] {
        let needle = title(query)
        func matches(_ value: String) -> Bool { exact ? value == needle : value.contains(needle) }
        var groups: [BookSearchGroup] = [], indices: [String: Int] = [:]
        for (index, hit) in hits.enumerated() {
            let name = title(hit.novel.title), writer = author(hit.novel.author)
            let accepted: Bool
            switch field {
            case .all: accepted = !exact || matches(name) || (!writer.isEmpty && matches(writer))
            case .title: accepted = matches(name)
            case .author: accepted = !writer.isEmpty && matches(writer)
            }
            guard accepted else { continue }
            // Unknown authors must not silently combine unrelated books with the same title.
            let key = merged && !writer.isEmpty ? "group:\(name.utf8.count):\(name)\(writer)" : "hit:" + hit.id
            if let old = indices[key] { groups[old].variants.append(hit) }
            else { indices[key] = groups.count; groups.append(BookSearchGroup(id: key, variants: [hit], firstIndex: index)) }
        }
        func rank(_ group: BookSearchGroup) -> Int {
            let book = group.representative.novel
            if title(book.title) == needle { return 0 }
            if author(book.author) == needle { return 1 }
            if title(book.title).hasPrefix(needle) { return 2 }
            if title(book.title).contains(needle) { return 3 }
            return 4
        }
        func speed(_ group: BookSearchGroup) -> Int { group.variants.compactMap(\.elapsedMilliseconds).min() ?? Int.max }
        return groups.sorted { a, b in
            switch sort {
            case .relevance: if rank(a) != rank(b) { return rank(a) < rank(b) }
            case .sources: if a.sourceCount != b.sourceCount { return a.sourceCount > b.sourceCount }
            case .title:
                let order = a.representative.novel.title.localizedStandardCompare(b.representative.novel.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .speed: if speed(a) != speed(b) { return speed(a) < speed(b) }
            case .arrival: break
            }
            return a.firstIndex < b.firstIndex
        }
    }
    public static func sourceGroups(_ source: BookSource) -> [String] {
        (source.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct BookSearchHistory: Codable, Equatable, Sendable {
    public private(set) var keywords: [String] = []
    public init() {}
    public init(keywords: [String]) { for value in keywords.prefix(30).reversed() { record(value) } }
    public mutating func record(_ text: String) {
        let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else { return }
        keywords.removeAll { BookSearchPresentation.normalized($0) == BookSearchPresentation.normalized(value) }
        keywords.insert(value, at: 0)
        keywords = Array(keywords.prefix(30))
    }
    public mutating func remove(_ text: String) { keywords.removeAll { $0 == text } }
    public mutating func clear() { keywords = [] }
}
