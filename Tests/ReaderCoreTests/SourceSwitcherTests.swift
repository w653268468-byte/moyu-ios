import Foundation
import XCTest
@testable import ReaderCore

final class SourceSwitcherTests: XCTestCase {
    private func chapters(_ titles: [String]) -> [OnlineChapter] {
        titles.enumerated().map { OnlineChapter(title: $0.element, url: URL(string: "https://fixture.example/\($0.offset)")!) }
    }
    func testNumberedChapterAlignmentAndAmbiguity() {
        XCTAssertEqual(ChapterAlignment.find("第一千零二章 风起", in: chapters(["第1001章 前夕", "第1002章 风起"])), 1)
        XCTAssertEqual(ChapterAlignment.find("第十二章", in: chapters(["Chapter 11", "Chapter 12"])), 1)
        XCTAssertEqual(ChapterAlignment.find("第十二章 风起", in: chapters(["第12章 风起", "第13章 风起"])), 0)
        XCTAssertNil(ChapterAlignment.find("第十二章 风起", in: chapters(["第13章 风起"])))
        XCTAssertNil(ChapterAlignment.find("第十二章", in: chapters(["第12章 上", "第12章 下"])))
        XCTAssertNil(ChapterAlignment.find("", in: chapters([""])))
        XCTAssertNil(ChapterAlignment.find("序章", in: chapters(["序章", "序章"])))
        XCTAssertEqual(ChapterAlignment.find("第二十章 海边的信", in: chapters(["第20章 海边的信"])), 0)
    }
    func testBookIdentityRequiresKnownMatchingAuthor() throws {
        let url = URL(string: "https://fixture.example")!
        let first = OnlineNovel(title: "《山 海》", author: "作者：Gavin", url: url, sourceID: "a")
        var second = OnlineNovel(title: "山海", author: "Gavin 著", url: url, sourceID: "b")
        XCTAssertTrue(BookIdentity.matches(first, second))
        second.author = ""
        XCTAssertFalse(BookIdentity.matches(first, second))
        XCTAssertTrue(BookIdentity.matches(first, second, allowMissingAuthor: true))
        let encoded = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(OnlineNovel.self, from: encoded).id, url.absoluteString)
        second.shelfID = "stable-shelf-entry"
        XCTAssertEqual(try JSONDecoder().decode(OnlineNovel.self, from: JSONEncoder().encode(second)).id, "stable-shelf-entry")
    }
}
