import Foundation
import XCTest
@testable import ReaderCore

final class DiscoveryCatalogTests: XCTestCase {
    func testHeadingsClassifyRankingsWithoutInventingThem() throws {
        let categories = try ExploreCategory.parse("排行榜\n周榜::/week\n月榜::/month\n分类\n玄幻::/fantasy\n都市::/city\n编辑推荐\n今日精选::/featured")
        let sections = DiscoveryCatalog.sections(categories)
        XCTAssertEqual(sections.map(\.lane), [.rankings, .rankings, .genres, .genres, .daily])
        XCTAssertEqual(sections.map(\.category.url), ["/week", "/month", "/fantasy", "/city", "/featured"])
        XCTAssertEqual(DiscoveryCatalog.dailyCategories(categories, day: "2026-10-31").map(\.url), ["/featured"])
        XCTAssertEqual(sections[2].group, "分类")
    }
    func testDailyFallbackIsStableAndNeverRequestsHeadings() throws {
        let categories = try ExploreCategory.parse("分类\n玄幻::/fantasy\n都市::/city\n历史::/history\n科幻::/science")
        let first = DiscoveryCatalog.dailyCategories(categories, day: "2026-10-31", limit: 2)
        XCTAssertEqual(first, DiscoveryCatalog.dailyCategories(categories, day: "2026-10-31", limit: 2))
        XCTAssertEqual(first.count, 2); XCTAssertTrue(first.allSatisfy { !$0.isHeading })
        XCTAssertTrue(DiscoveryCatalog.sections(categories).allSatisfy { $0.lane == .genres })
    }
    func testDailyRotationDeduplicatesBooksButKeepsWebsiteRankOrderSeparate() {
        let books = (0..<25).map { OnlineNovel(title: "书\($0)", url: URL(string: "https://books.example/\($0)")!, sourceID: "source") }
        let first = DiscoveryCatalog.dailyBooks(books + [books[0]], day: "2026-10-31")
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(first.map(\.id), DiscoveryCatalog.dailyBooks(books, day: "2026-10-31").map(\.id))
        XCTAssertNotEqual(first.map(\.id), DiscoveryCatalog.dailyBooks(books, day: "2026-10-31", batch: 1).map(\.id))
        XCTAssertEqual(books[0].title, "书0")
        XCTAssertTrue(DiscoveryCatalog.dailyBooks([], day: "2026-10-31").isEmpty)
    }
    func testDayKeyUsesCalendarAndTimezone() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = ISO8601DateFormatter().date(from: "2026-10-30T16:30:00Z")!
        XCTAssertEqual(DiscoveryCatalog.dayKey(date, calendar: calendar), "2026-10-31")
    }
}
