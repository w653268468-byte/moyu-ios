import XCTest
@testable import ReaderCore

final class ReadingProgressTests: XCTestCase {
    func testProgressEndpointsClampingAndRoundTrip() {
        XCTAssertNil(ReadingProgress.chapter(at: 0.5, count: 0))
        XCTAssertNil(ReadingProgress.chapter(at: .nan, count: 3))
        XCTAssertEqual(ReadingProgress.chapter(at: -1, count: 3), 0)
        XCTAssertEqual(ReadingProgress.chapter(at: 2, count: 3), 2)
        XCTAssertEqual(ReadingProgress.chapter(at: 1, count: 1), 0)
        for index in 0..<2601 {
            XCTAssertEqual(ReadingProgress.chapter(at: ReadingProgress.fraction(chapter: index, count: 2601), count: 2601), index)
        }
    }
    func testRefreshingCatalogKeepsChapterIdentityAndOffsetAfterInsertionAndReorder() {
        let first = OnlineChapter(title: "第一章", url: URL(string: "https://example.com/1")!)
        let second = OnlineChapter(title: "第二章", url: URL(string: "https://example.com/2")!)
        var old = OnlineNovel(title: "测试", url: URL(string: "https://example.com/book")!, sourceID: "test")
        old.chapters = [first, second]; old.chapterIndex = 1; old.textOffset = 57; old.scrollFraction = 0.3
        old.lastReadAt = Date(timeIntervalSince1970: 12)
        var updated = old; updated.chapters = [second, first]
        let saved = updated.preservingReadingPosition(from: old)
        XCTAssertEqual(saved.chapterIndex, 0)
        XCTAssertEqual(saved.textOffset, 57)
        XCTAssertEqual(saved.scrollFraction, 0.3)
        XCTAssertEqual(saved.lastReadAt, old.lastReadAt)
        updated.chapters = [first]
        let removed = updated.preservingReadingPosition(from: old)
        XCTAssertEqual(removed.chapterIndex, 0)
        XCTAssertEqual(removed.textOffset, 0, "Never apply a removed chapter's offset to unrelated content")
        XCTAssertEqual(removed.scrollFraction, 0)
        updated.chapters = []
        XCTAssertEqual(updated.preservingReadingPosition(from: old).chapterIndex, 0)
    }
}
