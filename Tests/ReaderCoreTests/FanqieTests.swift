import XCTest
@testable import ReaderCore

final class FanqieTests: XCTestCase {
    private let book = URL(string: "https://fanqienovel.com/page/7123456789012345678")!

    func testWholeShareMessageAndNumericID() throws {
        let link = try Fanqie.shareURL("推荐这本书 https://fanqienovel.com/page/7123456789012345678 一起看看")
        XCTAssertEqual(Fanqie.bookURL(in: link), book)
        XCTAssertEqual(try Fanqie.shareURL("7123456789012345678"), book)
    }

    func testQueryBookIDAndLookalikeDomain() throws {
        let shared = URL(string: "https://fanqienovel.com/share?book_id=7123456789012345678")!
        XCTAssertEqual(Fanqie.bookURL(in: shared), book)
        XCTAssertFalse(Fanqie.isOfficial(URL(string: "https://fanqienovel.com.evil.example/page/7123456789012345678")!))
        XCTAssertThrowsError(try Fanqie.shareURL("https://other.example/7123456789012345678"))
        XCTAssertFalse(Fanqie.isOfficial(URL(string: "https://user:password@fanqienovel.com/")!))
    }

    func testCatalogOrderAndDuplicates() throws {
        let html = """
        <div class="info-name"><h1>海边来信</h1></div>
        <span class="author-name-text">墨屿</span><div class="page-abstract-content">一封迟到的信。</div>
        <a href="/reader/7999999999999999999">最新章节</a>
        <div class="page-directory-content">
          <div class="chapter-item"><a href="/reader/7111111111111111111">第一章 风起</a></div>
          <div class="chapter-item"><a href="/reader/7222222222222222222">第二章 山海</a></div>
        </div>
        """
        let novel = try Fanqie.parseCatalog(html, url: book)
        XCTAssertEqual(novel.title, "海边来信")
        XCTAssertEqual(novel.author, "墨屿")
        XCTAssertEqual(novel.chapters.map(\.title), ["第一章 风起", "第二章 山海"])
        XCTAssertEqual(novel.sourceID, Fanqie.sourceID)
        XCTAssertEqual(novel.chapters[0].url.host, "fanqienovel.com")
    }

    func testMissingCatalogAndVerificationPageFailClearly() {
        XCTAssertThrowsError(try Fanqie.parseCatalog("<h1>请验证</h1>", url: book))
        XCTAssertThrowsError(try Fanqie.parseCatalog("<html></html>", url: book))
    }

    func testPublicPlainTextKeepsParagraphs() throws {
        let text = try Fanqie.parseChapter("<div class='muye-reader-content'><p>风从海边来。</p><p>她打开一封信。</p></div>")
        XCTAssertEqual(text, "风从海边来。\n\n她打开一封信。")
    }

    func testCustomFontGlyphsAreNeverShownAsPlainText() {
        XCTAssertThrowsError(try Fanqie.parseChapter("<div class='muye-reader-content'><p>海边\u{E000}信</p></div>")) { error in
            XCTAssertTrue(error.localizedDescription.contains("官方网页"))
        }
        XCTAssertThrowsError(try Fanqie.parseChapter("<h1>需要登录</h1>"))
    }

    func testReaderPageCanResolveBookLink() throws {
        let html = "<a href='/page/7123456789012345678'>返回书籍</a>"
        XCTAssertEqual(try Fanqie.bookLinkFromHTML(html, base: URL(string: "https://fanqienovel.com/reader/7333333333333333333")!), book)
    }
}
