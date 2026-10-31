import Foundation
import XCTest
@testable import ReaderCore

final class ReadingActivityTests: XCTestCase {
    func testDailyHistoryMergesBooksCapsTicksAndSurvivesReload() throws {
        var ledger = ReadingActivityLedger(), calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 86400)
        ledger.record(bookKey: "local:1", title: "书", chapter: "第一章", seconds: 15, at: day, calendar: calendar)
        ledger.record(bookKey: "local:1", title: "书", chapter: "第二章", seconds: 500, at: day.addingTimeInterval(30), calendar: calendar)
        ledger.record(bookKey: "local:1", title: "书", chapter: "第三章", seconds: 5, at: day.addingTimeInterval(86400), calendar: calendar)
        ledger.record(bookKey: "online:2", title: "另一本", chapter: "正文", seconds: .nan, calendar: calendar)
        let restored = try JSONDecoder().decode(ReadingActivityLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.entries.last?.seconds, 75)
        XCTAssertEqual(restored.entries.last?.chapter, "第二章")
        XCTAssertEqual(restored.entries.first?.day, "1970-01-03")
    }
    func testPrefetchIsBoundedAndPositionRequiresUniqueAnchor() {
        XCTAssertEqual(ReadingPrefetchPolicy.count(mode: "off", charactersPerMinute: 3000, chapterCharacters: 500), 0)
        XCTAssertEqual(ReadingPrefetchPolicy.count(mode: "auto", charactersPerMinute: 3000, chapterCharacters: 500), 6)
        XCTAssertEqual(ReadingPrefetchPolicy.count(mode: "auto", charactersPerMinute: .nan, chapterCharacters: 5000), 2)
        let body = (0..<100).map { "段落\($0)，春日故事。" }.joined()
        XCTAssertEqual(ChapterReadingPosition.alignedOffset(original: body, offset: 100, replacement: "序言" + body), 102)
        XCTAssertEqual(ChapterReadingPosition.alignedOffset(original: body, offset: 100, replacement: body + body), 0)
        XCTAssertEqual(ChapterReadingPosition.alignedOffset(original: body, offset: 100, replacement: "不同版本"), 0)
    }
    func testAutomaticCacheBudgetPreservesDownloadsAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent(String(repeating: "a", count: 64) + ".txt")
        let b = root.appendingPathComponent(String(repeating: "b", count: 64) + ".txt")
        try Data(repeating: 1, count: 50).write(to: a)
        try Data(repeating: 2, count: 50).write(to: b)
        try await AutomaticChapterCache(directory: root).register(a, budgetBytes: 100, protected: [a.lastPathComponent])
        try await AutomaticChapterCache(directory: root).register(b, budgetBytes: 50, protected: [a.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
    }
}
