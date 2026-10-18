import Foundation
import XCTest
@testable import ReaderCore

/// Explicit opt-in: external network checks are reported separately from deterministic tests.
final class LiveSourceTests: XCTestCase {
    func testPublicDomainSearchCatalogBodyAndEPUB() async throws {
        guard ProcessInfo.processInfo.environment["MOYU_LIVE_CHECK"] == "1" else { throw XCTSkip("Set MOYU_LIVE_CHECK=1 to test the public website") }
        let sourceJSON = #"""
        {"bookSourceName":"Gutenberg live check","bookSourceUrl":"https://www.gutenberg.org",
         "searchUrl":"/ebooks/search/?query={{key}}",
         "ruleSearch":{"bookList":"li.booklink","name":".title@text","bookUrl":"a.link@href"},
         "ruleBookInfo":{"name":"h1@text"},
         "ruleToc":{"chapterList":"a.read-online-button","chapterName":"text","chapterUrl":"href"},
         "ruleContent":{"content":".chapter@text"}}
        """#
        let source = try SourceImport.parse(Data(sourceJSON.utf8)).sources[0]
        let client = SourceClient()
        let books = try await client.search("Frankenstein", source: source)
        guard let book = books.first(where: { $0.url.path == "/ebooks/84" }) else { return XCTFail("Book 84 not found in live search") }
        let novel = try await client.catalog(book, source: source)
        XCTAssertEqual(novel.chapters.count, 1, "This public sample exposes the entire HTML book as one reading section")
        let content = try await client.chapter(novel.chapters[0], source: source)
        XCTAssertTrue(content.contains("Victor"))
        XCTAssertGreaterThan(content.count, 10000)
        let (epub, _) = try await client.fetch(URL(string: "https://www.gutenberg.org/ebooks/84.epub.noimages")!)
        let document = try LocalBookImporter.parse(epub, filename: "Frankenstein.epub")
        XCTAssertGreaterThan(document.chapters.count, 5)
        XCTAssertGreaterThan(document.wordCount, 10000)
        print("LIVE PASS: search → book 84 → HTML text; public EPUB \(document.chapters.count) reading sections, \(document.pages.count) segments")
    }
}
