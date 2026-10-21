import XCTest
@testable import ReaderCore

final class ChapterOrderTests: XCTestCase {
    func testReverseCatalogKeepsOriginalChapterDestinationsAndCanReturnToAscending() {
        let chapters = ["第一章", "第二章", "第三章"]
        let descending = ChapterOrder.indices(count: chapters.count, descending: true)
        XCTAssertEqual(descending.map { chapters[$0] }, ["第三章", "第二章", "第一章"])
        XCTAssertEqual(descending.first, 2, "Selecting the first reversed row must open original chapter 2, not 0")
        XCTAssertEqual(ChapterOrder.indices(count: chapters.count, descending: false), [0, 1, 2])
        XCTAssertEqual(chapters, ["第一章", "第二章", "第三章"], "Display sorting must not mutate catalog or saved positions")
    }
    func testEmptyAndSingleCatalogs() {
        XCTAssertTrue(ChapterOrder.indices(count: 0, descending: true).isEmpty)
        XCTAssertTrue(ChapterOrder.indices(count: -1, descending: false).isEmpty)
        XCTAssertEqual(ChapterOrder.indices(count: 1, descending: true), [0])
    }
}
