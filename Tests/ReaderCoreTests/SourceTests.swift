import XCTest
import SwiftSoup
@testable import ReaderCore

final class SourceTests: XCTestCase {
    private let sourceJSON = #"""
    {
      "bookSourceName":"测试书站", "bookSourceUrl":"https://books.example.org",
      "searchUrl":"/search?q={{key}}&page={{page}}",
      "ruleSearch":{"bookList":".book", "name":"a@text", "bookUrl":"a@href", "author":".author@text"},
      "ruleBookInfo":{"name":"h1@text", "tocUrl":".catalog@href"},
      "ruleToc":{"chapterList":"#list a", "chapterName":"text", "chapterUrl":"href"},
      "ruleContent":{"content":"#content@text"}
    }
    """#

    func testImportAndCompatibility() throws {
        let result = try SourceImport.parse(Data(sourceJSON.utf8))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertNil(result.sources[0].incompatibility)
        XCTAssertEqual(result.sources[0].searchUrl, "/search?q={{key}}&page={{page}}")
    }

    func testPartialImportReportsInvalidEntries() throws {
        let result = try SourceImport.parse(Data("[\(sourceJSON), {\"name\":\"bad\"}, 5]".utf8))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.failures.count, 2)
    }

    func testUnsupportedRulesNotSilentlyAccepted() throws {
        for rule in ["@js:result", "<js>1</js>", "$.data", "{{java.get()}}"] {
            XCTAssertFalse(HTMLRule.isSupported(rule), rule)
        }
        let bad = sourceJSON.replacingOccurrences(of: "#content@text", with: "{{java.get()}")
        XCTAssertNotNil(try SourceImport.parse(Data(bad.utf8)).sources[0].incompatibility)
    }

    func testCSSAndLegacySelectors() throws {
        let doc = try SwiftSoup.parse("<div class='book'><a href='/book/1'>山海</a><span class='author'>林屿</span></div>")
        let books = try HTMLRule.elements("class.book", in: doc)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(try HTMLRule.value("tag.a@text", in: books[0]), "山海")
        XCTAssertEqual(try HTMLRule.value("a@href", in: books[0]), "/book/1")
        XCTAssertEqual(try HTMLRule.value(".missing@text||.author@text", in: books[0]), "林屿")
    }

    func testBodyKeepsParagraphsAndDropsScripts() throws {
        let doc = try SwiftSoup.parse("<div id='content'>第一段<br>第二段<p>第三段</p><script>bad()</script></div>")
        let body = try HTMLRule.value("#content@html", in: doc, body: true)
        XCTAssertTrue(body.contains("第一段\n\n第二段"))
        XCTAssertTrue(body.contains("第三段"))
        XCTAssertFalse(body.contains("bad()"))
        XCTAssertEqual(try doc.select("script").array().count, 1, "Extraction must not mutate the original document")
    }

    func testRegexReplacement() throws {
        let doc = try SwiftSoup.parse("<h1>书名：山海</h1>")
        XCTAssertEqual(try HTMLRule.value("h1@text##^书名：##", in: doc), "山海")
    }

    func testLegacyIndexesUseMatchedCollection() throws {
        let doc = try SwiftSoup.parse("<h1>标题</h1><div class='book'>甲</div><p>间隔</p><div class='book'>乙</div>")
        XCTAssertEqual(try HTMLRule.value("class.book.0@text", in: doc), "甲")
        XCTAssertEqual(try HTMLRule.value("class.book.-1@text", in: doc), "乙")
        XCTAssertEqual(try HTMLRule.value("class.book.8@text", in: doc), "")
    }

    func testCommonMetadataXPathShape() throws {
        let rule = "//meta[@property='og:novel:author']/@content"
        let doc = try SwiftSoup.parse("<meta property='og:novel:author' content='林屿'>")
        XCTAssertTrue(HTMLRule.isSupported(rule))
        XCTAssertEqual(try HTMLRule.value(rule, in: doc), "林屿")
        XCTAssertTrue(HTMLRule.isSupported("//div[@id='content']/p"))
    }

    func testGeneralXPathListsAttributesAndText() throws {
        let doc = try SwiftSoup.parse("<section><div class='book'><a href='/a'><b>山海</b></a></div><div class='book'><a href='/b'>来信</a></div></section>")
        let books = try HTMLRule.elements("//div[@class='book']", in: doc)
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(try HTMLRule.value(".//a/@href", in: books[1]), "/b")
        XCTAssertEqual(try HTMLRule.value("@XPath:.//a", in: books[0]), "山海")
        XCTAssertEqual(try HTMLRule.value("//div[@class='book'][2]/a/text()", in: doc), "来信")
        XCTAssertThrowsError(try HTMLRule.value("//div[", in: doc))
    }

    func testTextSelectorForNextPage() throws {
        let doc = try SwiftSoup.parse("<div class='nav'><span><a href='/prev'>上一页</a><a href='/next'>下一页</a></span></div>")
        XCTAssertEqual(try HTMLRule.value("class.nav.0@tag.span.-1@text.下一页.0@href", in: doc), "/next")
    }

    func testURLResolutionAndRejectedSchemes() throws {
        let base = URL(string: "https://books.example.org/novel/1/")!
        XCTAssertEqual(try SourceClient.resolve("../2.html", base: base).absoluteString, "https://books.example.org/novel/2.html")
        XCTAssertThrowsError(try SourceClient.resolve("javascript:alert(1)", base: base))
        XCTAssertThrowsError(try SourceClient.resolve("file:///etc/passwd", base: base))
        XCTAssertThrowsError(try SourceClient.resolve("https://user:password@example.org", base: base))
    }
}
