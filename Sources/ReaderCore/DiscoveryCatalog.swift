import Foundation
import CryptoKit

public enum DiscoveryLane: String, CaseIterable, Hashable, Sendable {
    case daily = "每日推荐", rankings = "排行榜", genres = "分类"
}

public struct DiscoveryCategory: Identifiable, Equatable, Sendable {
    public let category: ExploreCategory
    public let group: String
    public let lane: DiscoveryLane
    public let position: Int
    public var id: String { category.id }
}

public enum DiscoveryCatalog {
    public static func sections(_ categories: [ExploreCategory]) -> [DiscoveryCategory] {
        var heading = "分类"
        return categories.enumerated().compactMap { position, category in
            if category.isHeading { heading = category.title; return nil }
            let name = (heading + " " + category.title).lowercased()
            let rankings = ["排行", "榜", "点击", "收藏", "人气", "畅销", "月票", "推荐票", "热度", "top", "ranking", "popular"]
            let daily = ["推荐", "精选", "书单", "编辑", "每日", "精品", "recommend", "featured"]
            let lane: DiscoveryLane = rankings.contains(where: name.contains) ? .rankings : daily.contains(where: name.contains) ? .daily : .genres
            return DiscoveryCategory(category: category, group: heading, lane: lane, position: position)
        }
    }

    public static func refreshed(_ selected: DiscoveryCategory, in categories: [ExploreCategory]) throws -> ExploreCategory {
        let options = sections(categories)
        if let exact = options.first(where: { $0.id == selected.id }) { return exact.category }
        if let samePosition = options.first(where: { $0.position == selected.position && $0.group == selected.group && $0.category.title == selected.category.title }) { return samePosition.category }
        let matching = options.filter { $0.group == selected.group && $0.category.title == selected.category.title }
        guard matching.count == 1 else { throw SourceError.message("发现分类已变化，请返回刷新后重新选择。") }
        return matching[0].category
    }

    public static func dayKey(_ date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func score(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pick actual source lists; headings never become requests. A daily seed keeps
    /// the choice stable across restarts without inventing a website's ranking.
    public static func dailyCategories(_ categories: [ExploreCategory], day: String, limit: Int = 3) -> [ExploreCategory] {
        let entries = sections(categories)
        let featured = entries.filter { $0.lane == .daily }
        let candidates = featured.isEmpty ? entries : featured
        return candidates.map { (entry: $0, key: score(day + $0.id)) }.sorted { $0.key < $1.key }
            .prefix(max(0, min(6, limit))).map(\.entry.category)
    }

    public static func dailyBooks(_ books: [OnlineNovel], day: String, batch: Int = 0, limit: Int = 12) -> [OnlineNovel] {
        var seen = Set<String>()
        let unique = books.filter { seen.insert($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + $0.author.lowercased()).inserted }
            .map { (book: $0, key: score(day + $0.id)) }.sorted { $0.key < $1.key }.map(\.book)
        guard !unique.isEmpty else { return [] }
        let count = min(max(0, limit), unique.count)
        let offset = ((max(0, batch) % unique.count) * count) % unique.count
        return (0..<count).map { unique[(offset + $0) % unique.count] }
    }
}
