import XCTest
@testable import ReaderCore

final class TextParserTests: XCTestCase {
    func testChineseChaptersAndPreamble() throws {
        let doc = try TextParser.parse("前言\r\n第一章 初见\r\n正文甲\r\n第二章 夜雨\r\n正文乙")
        XCTAssertEqual(doc.chapters.map(\.title), ["正文", "第一章 初见", "第二章 夜雨"])
        XCTAssertEqual(doc.chapters.map(\.firstPage), [0, 1, 2])
        XCTAssertEqual(doc.pages.map(\.chapter), [0, 1, 2])
    }

    func testLongUnicodeLinePreservesAllCharacters() throws {
        let text = String(repeating: "山🌙👨‍👩‍👧‍👦海", count: 1000)
        let doc = try TextParser.parse(text, pageSize: 81)
        XCTAssertGreaterThan(doc.pages.count, 1)
        XCTAssertEqual(doc.pages.map(\.text).joined(), text)
        XCTAssertTrue(doc.pages.allSatisfy { $0.text.count <= 81 })
    }

    func testEmptyRejected() {
        XCTAssertThrowsError(try TextParser.parse(" \n\r\n　"))
    }

    func testBOMAndUTF16() throws {
        let text = "第一章 春天\n风从海边来。"
        XCTAssertEqual(try TextParser.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text)
        XCTAssertEqual(try TextParser.decode(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!), text)
        XCTAssertEqual(try TextParser.decode(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!), text)
    }

    func testFileLimit() {
        XCTAssertThrowsError(try TextParser.decode(Data(repeating: 65, count: TextParser.maximumBytes + 1)))
    }

    func testEnglishHeadingAndSearch() throws {
        let doc = try TextParser.parse("Chapter 1 Dawn\nHello world\nChapter II Night\nGoodnight")
        XCTAssertEqual(doc.chapters.count, 2)
        XCTAssertEqual(doc.search("HELLO").map(\.id), [0])
        XCTAssertTrue(doc.search("  ").isEmpty)
    }

    func testSerializationRetainsBookmarksAndProgress() throws {
        let doc = try TextParser.parse("第一章 起点\n你好")
        var book = Book(title: "测试", document: doc)
        XCTAssertEqual(book.progress, 0)
        book.lastReadAt = Date()
        book.bookmarks = [Bookmark(page: 0, excerpt: "你好")]
        let copy = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(copy, book)
        XCTAssertEqual(copy.progress, 1)
        XCTAssertEqual(try JSONDecoder().decode(BookDocument.self, from: JSONEncoder().encode(doc)), doc)
    }
}
