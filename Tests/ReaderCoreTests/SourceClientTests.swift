import Foundation
import XCTest
@testable import ReaderCore

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let routes: [String: String] = [
            "/search": "<div class='book'><a href='/book/1'>山海来信</a><span class='author'>墨屿</span></div>",
            "/book/1": "<h1>山海来信</h1><a class='catalog' href='/toc/1'>目录</a>",
            "/toc/1": "<div id='list'><a href='/chapter/1'>第一章</a></div><a class='next' href='/toc/2'>下一页</a>",
            "/toc/2": "<div id='list'><a href='/chapter/1'>第一章</a><a href='/chapter/2'>第二章</a></div>",
            "/chapter/1": "<div id='content'>风从海边来。<br>她打开了信。</div><a class='next' href='/chapter/1_2'>下一页</a>",
            "/chapter/1_2": "<div id='content'><p>故事还没有结束。</p></div>",
            "/chapter/2": "<div id='content'>第二天，天晴了。</div>"
        ]
        guard let url = request.url else { return }
        let body = routes[url.path]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "Not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SourceClientTests: XCTestCase {
    private func makeClient() -> SourceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return SourceClient(configuration: config)
    }

    private func source() throws -> BookSource {
        let json = #"""
        {"bookSourceName":"Fixture","bookSourceUrl":"https://fixture.example",
         "searchUrl":"/search?q={{key}}&page={{page}}",
         "ruleSearch":{"bookList":".book","name":"a@text","bookUrl":"a@href","author":".author@text"},
         "ruleBookInfo":{"name":"h1@text","tocUrl":".catalog@href"},
         "ruleToc":{"chapterList":"#list a","chapterName":"text","chapterUrl":"href","nextTocUrl":".next@href"},
         "ruleContent":{"content":"#content@text","nextContentUrl":".next@href"}}
        """#
        return try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
    }

    func testSearchCatalogPaginationAndChapterContent() async throws {
        let client = makeClient()
        let source = try source()
        let books = try await client.search("山海", source: source)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "山海来信")
        XCTAssertEqual(books[0].author, "墨屿")
        let novel = try await client.catalog(books[0], source: source)
        XCTAssertEqual(novel.chapters.count, 2, "Catalog pages must be merged and deduplicated")
        XCTAssertEqual(novel.chapters[1].url.absoluteString, "https://fixture.example/chapter/2")
        let content = try await client.chapter(novel.chapters[0], source: source)
        XCTAssertTrue(content.contains("风从海边来。\n\n她打开了信。"))
        XCTAssertTrue(content.contains("故事还没有结束。"))
    }

    func testHTTPFailureIsVisible() async throws {
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/missing")!)
            XCTFail("HTTP 404 must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("网站返回错误")) }
    }

    func testStreamingResponseLimit() async throws {
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/search")!, limit: 5)
            XCTFail("Oversized response must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("大小限制")) }
    }
}
