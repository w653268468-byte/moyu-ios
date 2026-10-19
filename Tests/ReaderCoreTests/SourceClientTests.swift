import Foundation
import XCTest
@testable import ReaderCore

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        if request.url?.path == "/tlsfailure" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://redirect.example/source.json")!])); return
        }
        if request.url?.path == "/certificate" {
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)); return
        }
        let routes: [String: String] = [
            "/api/search": #"{"data":{"books":[{"name":"三国","url":"/api/book","bid":42}]}}"#,
            "/api/book": #"{"name":"三国","toc":"/api/toc"}"#,
            "/api/toc": #"{"chapters":[{"title":"第一回","url":"/api/chapter"}]}"#,
            "/api/chapter": #"{"text":"滚滚长江东逝水。"}"#,
            "/api/script-search": #"{"data":{"books":[{"title":"公版故事","sourceUuid":"one"}]}}"#,
            "/source/one": "<div class='m-book-recent'><a>最新章</a></div>",
            "/helpers.js": "function sharedTitle(value) { return value + '共享脚本'; }",
            "/search": "<div class='book'><a href='/book/1'>山海来信</a><span class='author'>Gavin</span></div>",
            "/book/1": "<h1>山海来信</h1><a class='catalog' href='/toc/1'>目录</a>",
            "/toc/1": "<div id='list'><a href='/chapter/1'>第一章</a></div><a class='next' href='/toc/2'>下一页</a>",
            "/toc/2": "<div id='list'><a href='/chapter/1'>第一章</a><a href='/chapter/2'>第二章</a></div>",
            "/chapter/1": "<div id='content'>风从海边来。<br>她打开了信。</div><a class='next' href='/chapter/1_2'>下一页</a>",
            "/chapter/1_2": "<div id='content'><p>故事还没有结束。</p></div>",
            "/chapter/2": "<div id='content'>第二天，天晴了。</div>"
        ]
        guard let url = request.url else { return }
        let body = url.path == "/js-search" && request.value(forHTTPHeaderField: "X-Reader") == "Gavin" ? routes["/search"] : routes[url.path]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "Not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SourceClientTests: XCTestCase {
    func testTLSHandshakeAndCertificateFailuresAreDistinguished() async {
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/tlsfailure")!)
            XCTFail("Expected handshake failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("redirect.example"))
            XCTAssertTrue(error.localizedDescription.contains("加密连接建立失败"))
            XCTAssertFalse(error.localizedDescription.contains("证书验证失败"))
        }
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/certificate")!)
            XCTFail("Expected certificate failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("证书验证失败")) }
    }
    func testSharedScriptLibrariesLoadBeforeSearchRules() async throws {
        for library in ["function sharedTitle(value) { return value + '共享脚本'; }", #"{"helpers":"/helpers.js"}"#] {
            var source = try source()
            source.jsLib = library
            source.ruleSearch?.name = "a@text@js:sharedTitle(result)"
            let found = try await makeClient().search("山海", source: source)
            XCTAssertEqual(found.first?.title, "山海来信共享脚本")
        }
    }
    func testWebViewOptionsReachRendererAndSurviveSavedChapter() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let client = SourceClient(configuration: config, webRenderer: { request, _ in
            guard SourceRequest.requiresWebView(request), request.url?.path == "/chapter/1", request.value(forHTTPHeaderField: "Referer") != nil else { throw SourceError.message("WebView option lost") }
            return (Data("<div id='content'>动态生成的正文</div>".utf8), request.url!)
        })
        var source = try source(); source.ruleContent?.nextContentUrl = nil
        let navigation = try SourceRequest.navigation("../chapter/1,{'webView':'true','webJs':'document.body.innerHTML'}", base: URL(string: "https://fixture.example/book/toc")!, script: nil)
        let chapter = OnlineChapter(title: "第一章", url: navigation.url, requestTemplate: navigation.template)
        let saved = try JSONDecoder().decode(OnlineChapter.self, from: JSONEncoder().encode(chapter))
        XCTAssertEqual(saved.url.path, "/chapter/1")
        XCTAssertNotEqual(saved.id, saved.url.absoluteString, "Chapter request options must not share cache keys")
        let body = try await client.chapter(saved, source: source)
        XCTAssertEqual(body, "动态生成的正文")
        let request = try SourceRequest.make(saved.requestTemplate!, query: "", base: saved.url)
        XCTAssertEqual(SourceRequest.webScript(request), "document.body.innerHTML")
    }
    func testTemplateBookURLAndVariablesSurviveReaderRestart() async throws {
        var source = try source()
        source.searchUrl = "/api/search"
        source.ruleSearch?.bookList = "$.data.books[*]"
        source.ruleSearch?.name = "$.name"
        source.ruleSearch?.author = nil
        source.ruleSearch?.bookUrl = "{{$.url}}?bid=@get:{bid}"
        source.ruleSearch?.wordCount = "@put:{bid:$.bid}"
        source.ruleBookInfo?.name = "$.name"
        source.ruleBookInfo?.tocUrl = "https://fixture.example/api/toc?bid=@get:{bid}"
        source.ruleToc?.chapterList = "$.chapters[*]"; source.ruleToc?.chapterName = "title"; source.ruleToc?.chapterUrl = "url"; source.ruleToc?.nextTocUrl = nil
        source.ruleContent?.content = "$.text"; source.ruleContent?.nextContentUrl = nil
        let books = try await makeClient().search("三国", source: source)
        XCTAssertEqual(books.first?.ruleVariables?["bid"], "42")
        XCTAssertEqual(books.first?.url.query, "bid=42")
        let restored = try JSONDecoder().decode(OnlineNovel.self, from: JSONEncoder().encode(books[0]))
        let catalog = try await makeClient().catalog(restored, source: source)
        XCTAssertEqual(catalog.chapters.first?.ruleVariables?["bid"], "42")
        let text = try await makeClient().chapter(catalog.chapters[0], source: source)
        XCTAssertEqual(text, "滚滚长江东逝水。")
    }
    func testAutomaticSourceSwitchReadsBodyBeforeMigratingIdentity() async throws {
        let client = makeClient()
        let working = try source()
        var failed = working
        failed.bookSourceUrl = "https://fixture.example/broken"
        failed.searchUrl = "/timeout"
        let originalURL = URL(string: "https://original.example/book")!
        var original = OnlineNovel(title: "《山海来信》", author: "作者：Gavin", url: originalURL, sourceID: "old-source")
        original.chapters = [OnlineChapter(title: "第1章", url: originalURL)]
        let result = try await SourceSwitcher(client: client).automatic(original, chapterIndex: 0, sources: [failed, working])
        XCTAssertEqual(result.novel.id, original.id)
        XCTAssertEqual(result.novel.sourceID, working.id)
        XCTAssertEqual(result.novel.chapterIndex, 0)
        XCTAssertEqual(result.novel.textOffset, 0)
        XCTAssertTrue(result.text.contains("风从海边来。"))
        original.author = "其他作者"
        do {
            _ = try await SourceSwitcher(client: client).automatic(original, chapterIndex: 0, sources: [working])
            XCTFail("Same title by a different author must never switch automatically")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未找到可靠")) }
    }

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
        XCTAssertEqual(books[0].author, "Gavin")
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

    func testScriptSearchCatalogAndBodyUseRealRequestPipeline() async throws {
        var source = try source()
        source.ruleSearch?.bookList = "@js:java.getElements('.book')"
        source.ruleSearch?.name = "a@text@js:result.trim()"
        source.ruleToc?.chapterList = "#list a<js>result.toArray()</js>"
        source.ruleContent?.content = "#content@text@js:result + '\\n' + source.bookSourceName"
        XCTAssertNil(source.incompatibility)
        let client = makeClient()
        let books = try await client.search("山海", source: source)
        XCTAssertEqual(books.first?.title, "山海来信")
        let book = try await client.catalog(books[0], source: source)
        XCTAssertEqual(book.chapters.count, 2)
        let text = try await client.chapter(book.chapters[0], source: source)
        XCTAssertTrue(text.contains("风从海边来。"))
        XCTAssertTrue(text.contains("Fixture"))
    }

    func testScriptAjaxAndResponseBridgeShareRequestConfiguration() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let script = try SourceScript(configuration: config)
        let url = URL(string: "https://fixture.example")!
        XCTAssertEqual(try script.evaluate("JSON.parse(java.ajax('/api/chapter')).text", result: "", baseURL: url) as? String, "滚滚长江东逝水。")
        XCTAssertEqual(try script.evaluate("JSON.parse(java.get('https://fixture.example/api/chapter').body()).text", result: "", baseURL: url) as? String, "滚滚长江东逝水。")
        XCTAssertThrowsError(try script.evaluate("java.ajax('/missing')", result: "", baseURL: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTTP 404"))
        }
    }
    func testScriptURLAndHeadersActuallyReachSearch() async throws {
        var source = try source()
        source.searchUrl = "@js:'/js-search?q=' + encodeURIComponent(key)"
        source.header = "@js:JSON.stringify({'X-Reader':'Gavin'})"
        XCTAssertNil(source.incompatibility)
        let found = try await makeClient().search("中文 空格", source: source)
        XCTAssertEqual(found.first?.title, "山海来信")
    }
    func testJSONPrefixAndJsoupCollectionPatternUsedByImportedSources() async throws {
        var source = try source()
        source.searchUrl = "/api/script-search"
        source.ruleSearch?.bookList = "data.books[*]@js:JSON.parse(result).map(o => ({name:o.title,url:'/api/book',author:org.jsoup.Jsoup.parse(java.ajax('/source/'+o.sourceUuid)).select('.m-book-recent a').text()}))"
        source.ruleSearch?.name = "name"
        source.ruleSearch?.bookUrl = "url"
        source.ruleSearch?.author = "author"
        let books = try await makeClient().search("故事", source: source)
        XCTAssertEqual(books.first?.title, "公版故事")
        XCTAssertEqual(books.first?.author, "最新章")
    }
    func testExploreCategoriesAndPagedBookList() async throws {
        var source = try source()
        source.exploreUrl = "@js:JSON.stringify([{title:'推荐',url:'/search?page={{page}}'}])"
        source.ruleExplore = source.ruleSearch
        source.ruleExplore?.name = "a@text@js:result + (page === 2 ? '第二页' : '错误')"
        let client = makeClient()
        let categories = try await client.categories(source: source)
        XCTAssertEqual(categories.map(\.title), ["推荐"])
        let found = try await client.explore(categories[0], page: 2, source: source)
        XCTAssertEqual(found.first?.title, "山海来信第二页")
        XCTAssertEqual(found.first?.url.absoluteString, "https://fixture.example/book/1")
    }

    func testStreamingResponseLimit() async throws {
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/search")!, limit: 5)
            XCTFail("Oversized response must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("大小限制")) }
    }

    func testJSONPOSTSearchCatalogAndBody() async throws {
        let json = #"""
        {"bookSourceName":"JSON fixture","bookSourceUrl":"https://fixture.example",
         "searchUrl":"/api/search,{'method':'POST','body':'key={{key}}'}",
         "ruleSearch":{"bookList":"$.data.books[*]","name":"name","bookUrl":"url"},
         "ruleBookInfo":{"name":"$.name","tocUrl":"toc"},
         "ruleToc":{"chapterList":"$.chapters[*]","chapterName":"title","chapterUrl":"url"},
         "ruleContent":{"content":"$.text"}}
        """#
        let source = try SourceImport.parse(Data(json.utf8)).sources[0]
        XCTAssertNil(source.incompatibility)
        let client = makeClient()
        let books = try await client.search("三国", source: source)
        XCTAssertEqual(books.count, 1)
        let novel = try await client.catalog(books[0], source: source)
        XCTAssertEqual(novel.chapters.count, 1)
        let text = try await client.chapter(novel.chapters[0], source: source)
        XCTAssertEqual(text, "滚滚长江东逝水。")
    }

    func testTimeoutReportsNetworkStageAndHost() async throws {
        do {
            _ = try await makeClient().fetch(URL(string: "https://fixture.example/timeout")!)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture.example"))
            XCTAssertTrue(error.localizedDescription.contains("超时"))
            XCTAssertTrue(error.localizedDescription.contains("-1001"))
        }
    }
}
