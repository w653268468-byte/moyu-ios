import Foundation
import XCTest
@testable import ReaderCore

/// Explicit opt-in: external network checks are reported separately from deterministic tests.
final class LiveSourceTests: XCTestCase {
    func testUserProvidedYioveCollection() async throws {
        guard ProcessInfo.processInfo.environment["MOYU_LIVE_CHECK"] == "1" else { throw XCTSkip("Live network check disabled") }
        let result = try await SourceClient().importText("https://shuyuan-api.yiove.com/import/book-source-collection/a8adf570-e115-4b99-87e3-ccaf298ae361")
        XCTAssertFalse(result.sources.isEmpty)
        print("YIOVE IMPORT: \(result.sources.count) sources; \(result.failures.count) entry errors. Import is not website availability validation.")
    }
    func testUserProvidedYuancSubscriptionIndex() async throws {
        guard ProcessInfo.processInfo.environment["MOYU_LIVE_CHECK"] == "1" else { throw XCTSkip("Live network check disabled") }
        let client = SourceClient()
        let result = try await client.importURL(URL(string: "https://github.com/52liulian/yuanc")!)
        XCTAssertFalse(result.sources.isEmpty)
        let compatible = result.sources.filter { $0.incompatibility == nil }
        print("YUANC IMPORT: \(result.sources.count) unique sources; \(compatible.count) recognized by current engine; \(result.failures.count) subscription/entry errors. Recognition is not live website validation.")
    }
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
        var discovery = source
        discovery.exploreUrl = "下载排行榜::/browse/scores/top"
        discovery.ruleExplore = try JSONDecoder().decode(SourceRule.self, from: Data(##"{"bookList":"#books-last1 + ol li","name":"a@text","bookUrl":"a@href"}"##.utf8))
        let categories = try await client.categories(source: discovery)
        let ranking = try await client.explore(categories[0], page: 1, source: discovery)
        XCTAssertGreaterThan(ranking.count, 50)
        XCTAssertTrue(ranking.allSatisfy { $0.url.host == "www.gutenberg.org" && $0.url.path.hasPrefix("/ebooks/") })
        print("LIVE DISCOVERY PASS: official download ranking → \(ranking.count) distinct book links in website order")
    }
}
