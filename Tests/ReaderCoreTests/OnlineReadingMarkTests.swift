import Foundation
import XCTest
@testable import ReaderCore

final class OnlineReadingMarkTests: XCTestCase {
    func testUTF16BoundaryPersistenceAndSourceChangeChapterMatching() throws {
        let chapter = OnlineChapter(title: "第二章", url: URL(string: "https://old.example/two")!)
        let mark = OnlineReadingMark(chapter: chapter, index: 1, offset: 2, text: "a🌸花开了")
        XCTAssertEqual(mark.textOffset, 1)
        XCTAssertEqual(mark.excerpt, "🌸花开了")
        XCTAssertEqual(try JSONDecoder().decode(OnlineReadingMark.self, from: JSONEncoder().encode(mark)), mark)
        let new = [OnlineChapter(title: "第一章", url: URL(string: "https://new.example/one")!), OnlineChapter(title: "第二章", url: URL(string: "https://new.example/two")!)]
        XCTAssertEqual(mark.destination(in: new), 1)
        XCTAssertNil(mark.destination(in: []))
        XCTAssertNil(mark.destination(in: [new[1], new[0], new[1]]), "Ambiguous renamed/reordered chapter lists must not jump silently")
    }
    func testOldShelfWithoutMetadataOrBookmarksStillDecodes() throws {
        let json = #"{"title":"老书","author":"作者","intro":"","url":"https://example.org/book","sourceID":"old","chapters":[],"chapterIndex":0}"#
        let book = try JSONDecoder().decode(OnlineNovel.self, from: Data(json.utf8))
        XCTAssertNil(book.readingMarks); XCTAssertNil(book.coverURL)
    }
}
