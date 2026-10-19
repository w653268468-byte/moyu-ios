import Foundation
import XCTest
@testable import ReaderCore

private final class ScriptAjaxBarrier: @unchecked Sendable {
    static let shared = ScriptAjaxBarrier()
    private let lock = NSLock()
    private var open = false
    private var callback: (() -> Void)?
    func reset() { lock.lock(); open = false; callback = nil; lock.unlock() }
    func wait(_ action: @escaping () -> Void) { lock.lock(); if open { lock.unlock(); action() } else { callback = action; lock.unlock() } }
    func release() { lock.lock(); open = true; let action = callback; callback = nil; lock.unlock(); action?() }
}

private final class FixtureProtocol: URLProtocol {
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url, url.path == "/blocked-script" {
            ScriptAjaxBarrier.shared.wait { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data("ready".utf8)); self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if request.url?.path == "/release-script" { ScriptAjaxBarrier.shared.release() }
        if let url = request.url, url.path == "/lease-search" {
            let slow = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "slow" })?.value == "1"
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/html; charset=utf-8"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data("<div class='book'><a href='/book/1'>故事</a></div>".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + (slow ? 1 : 0.005), execute: work)
            return
        }
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
            "/chapter/1_2": "<div id='content'><p>故事还没有结束。</p></div><a class='next' href='/chapter/2'>下一章</a>",
            "/chapter/2": "<div id='content'>第二天，天晴了。" + String(repeating: "真实正文测试。", count: 40) + "</div>"
        ]
        guard let url = request.url else { return }
        var body = url.path == "/js-search" && request.value(forHTTPHeaderField: "X-Reader") == "Gavin" ? routes["/search"] : routes[url.path]
        if url.path == "/release-script" { body = routes["/search"] }
        if url.path == "/auth-search", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture", request.value(forHTTPHeaderField: "Cookie") == "sid=fixture" { body = routes["/search"] }
        if url.path == "/okhttp-post", request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == "application/json", request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
            var prefix = request.httpBody.map { Data($0.prefix(2)) }
            if prefix == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 2)
                let count = stream.read(&bytes, maxLength: 2)
                if count > 0 { prefix = Data(bytes.prefix(count)) }
            }
            if prefix == Data([0x1f,0x8b]) { body = #"{"ok":true}"# }
        }
        if url.path == "/paged-search" {
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
            body = page == "1" ? routes["/search"] : page == "2" ? "<div class='book'><a href='/book/2'>第二本</a></div>" : "<p>No more results</p>"
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "Not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { pending?.cancel() }
}

private actor SearchOutcomeRecorder {
    var values: [SourceSearchOutcome] = []
    func append(_ value: SourceSearchOutcome) { values.append(value) }
}

final class SourceClientTests: XCTestCase {
    func testSharedSourceValidatorReadsPastShortPrefaceBeforePassing() async throws {
        let report = try await SourceValidator.validate(source(), client: makeClient())
        XCTAssertEqual(report.title, "山海来信"); XCTAssertEqual(report.chapters, 2)
        XCTAssertEqual(report.chapterIndex, 1)
        XCTAssertGreaterThanOrEqual(report.characters, SourceValidator.minimumCharacters)
    }
    func testSharedSourceValidatorRejectsShortPlaceholderBodies() async throws {
        var source = try source(); source.ruleContent?.content = "@js:'网站提示文字'"
        do { _ = try await SourceValidator.validate(source, client: makeClient()); XCTFail("Short placeholder passed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("正文不足")) }
    }
    func testOkHttpBuilderSendsBinaryGzipBodyThroughNativePipeline() throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let script = try SourceScript(configuration: config)
        let code = "with(new JavaImporter(Packages.okhttp3,Packages.cn.hutool.core.util)){var body=RequestBody.create(ZipUtil.gzip(JSON.stringify({q:'故事'})),MediaType.parse('application/json'));var request=new Request.Builder().url('https://fixture.example/okhttp-post').post(body).addHeader('Content-Encoding','gzip').build();JSON.parse(new OkHttpClient().newCall(request).execute().body().string()).ok}"
        XCTAssertEqual(try script.evaluate(code, result: "", baseURL: URL(string: "https://fixture.example")!) as? Bool, true)
    }
    func testBookInitializationReplacesDocumentBeforeMetadataAndCatalog() async throws {
        var source = try source()
        source.ruleBookInfo?.initialization = "@js:const value=JSON.parse(result);({name:value.name+'初始化',toc:value.toc})"
        source.ruleBookInfo?.name = "$.name"; source.ruleBookInfo?.author = nil; source.ruleBookInfo?.intro = nil
        source.ruleBookInfo?.tocUrl = "$.toc"
        source.ruleToc?.chapterList = "$.chapters[*]"; source.ruleToc?.chapterName = "$.title"; source.ruleToc?.chapterUrl = "$.url"; source.ruleToc?.nextTocUrl = nil
        let book = OnlineNovel(title: "Before", url: URL(string: "https://fixture.example/api/book")!, sourceID: source.id)
        let parsed = try await makeClient().catalog(book, source: source)
        XCTAssertEqual(parsed.title, "三国初始化"); XCTAssertEqual(parsed.chapters.count, 1)
    }
    func testScriptAjaxDoesNotBlockOtherSourceActors() async throws {
        ScriptAjaxBarrier.shared.reset(); defer { ScriptAjaxBarrier.shared.release() }
        var slow = try source(), fast = try source()
        slow.bookSourceUrl = "https://fixture.example/slow"
        slow.searchUrl = "@js:java.ajax('https://fixture.example/blocked-script'); '/search'"
        fast.bookSourceUrl = "https://fixture.example/fast"; fast.searchUrl = "/release-script"
        let client = makeClient(), recorder = SearchOutcomeRecorder()
        try await SourceSearch.run(requests: [slow, fast].map { SourceSearchRequest(source: $0, page: 1) }, concurrency: 2, timeoutSeconds: 5, search: { source, page in
            try await client.searchIndependent("公版", source: source, page: page)
        }, onResult: { await recorder.append($0); return true })
        let outcomes = await recorder.values
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.failure == nil && $0.novels.count == 1 }, "A script waiting for another source must not serialize the global search")
    }
    func testIndependentSourceKeepsScriptVariablesAcrossPages() async throws {
        var source = try source()
        source.searchUrl = "@js:java.put('visits',String(Number(java.get('visits')||0)+1)); '/search'"
        source.ruleSearch?.name = "a@text@js:result + java.get('visits')"
        let client = makeClient()
        let first = try await client.searchIndependent("故事", source: source, page: 1)
        let second = try await client.searchIndependent("故事", source: source, page: 2)
        XCTAssertEqual(first.first?.title, "山海来信1")
        XCTAssertEqual(second.first?.title, "山海来信2")
    }
    func testIndependentPaginationSurvivesInterpreterCacheEviction() async throws {
        let client = makeClient()
        var sources: [BookSource] = []
        for index in 0..<17 {
            var item = try source()
            item.bookSourceUrl = "https://fixture.example/source-\(index)"
            item.searchUrl = "@js:java.put('visits',String(Number(java.get('visits')||0)+1)); '/search'"
            item.ruleSearch?.name = "a@text@js:result + java.get('visits')"
            sources.append(item)
            let first = try await client.searchIndependent("故事", source: item, page: 1)
            XCTAssertEqual(first.first?.title, "山海来信1")
        }
        for item in sources {
            let next = try await client.searchIndependent("故事", source: item, page: 2)
            XCTAssertEqual(next.first?.title, "山海来信2")
        }
    }
    func testIndependentSearchDoesNotLeakVariablesBetweenKeywords() async throws {
        var source = try source()
        source.searchUrl = "@js:java.put('visits',String(Number(java.get('visits')||0)+1)); '/search'"
        source.ruleSearch?.name = "a@text@js:result + java.get('visits')"
        let client = makeClient()
        _ = try await client.searchIndependent("第一本", source: source)
        let second = try await client.searchIndependent("另一本", source: source)
        XCTAssertEqual(second.first?.title, "山海来信1")
    }
    func testRepeatedKeywordUsesFreshSessionButResumeKeepsVariables() async throws {
        var source = try source()
        source.searchUrl = "@js:java.put('visits',String(Number(java.get('visits')||0)+1)); '/search'"
        source.ruleSearch?.name = "a@text@js:result + java.get('visits')"
        let client = makeClient(), firstSession = UUID()
        let first = try await client.searchIndependent("同一个词", source: source, sessionID: firstSession)
        let next = try await client.searchIndependent("同一个词", source: source, page: 2, sessionID: firstSession)
        let restarted = try await client.searchIndependent("同一个词", source: source, sessionID: UUID())
        XCTAssertEqual(first.first?.title, "山海来信1")
        XCTAssertEqual(next.first?.title, "山海来信2")
        XCTAssertEqual(restarted.first?.title, "山海来信1")
    }
    func testSearchIsNotBlockedByUnsupportedBodyRule() async throws {
        var source = try source()
        source.ruleContent?.content = "{{java.get()}"
        XCTAssertNotNil(source.incompatibility)
        XCTAssertNil(source.searchIncompatibility)
        let found = try await makeClient().search("故事", source: source)
        XCTAssertEqual(found.first?.title, "山海来信")
    }
    func testImportTextRecognizesJSONAndPreservesSuccessfulLinks() async throws {
        let client = makeClient()
        let json = try SourceImport.export([source()])
        let pasted = try await client.importText(String(decoding: json, as: UTF8.self))
        XCTAssertEqual(pasted.sources.count, 1)
        XCTAssertTrue(pasted.diagnostics.first?.contains("JSON") == true)
        do {
            _ = try await client.importText("https://fixture.example/timeout\nhttps://fixture.example/tlsfailure")
            XCTFail("Failed downloads must not yield an empty success preview")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("链接 1"))
            XCTAssertTrue(error.localizedDescription.contains("链接 2"))
            XCTAssertTrue(error.localizedDescription.contains("超时"))
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }
    }
    func testActiveScriptVariablesSurviveOtherSourcesFinishingFirst() async throws {
        let client = makeClient(), recorder = SearchOutcomeRecorder()
        let jobs = try (0..<14).map { index -> SourceSearchRequest in
            var source = try source()
            source.bookSourceName = "Pinned\(index)"
            source.bookSourceUrl = "https://fixture.example/source\(index)"
            source.searchUrl = "@js:java.put('lease',source.bookSourceName); '/lease-search?slow='+(source.bookSourceName==='Pinned0'?'1':'0')"
            source.ruleSearch?.name = "a@text@js:result + java.get('lease')"
            return SourceSearchRequest(source: source, page: 1)
        }
        try await SourceSearch.run(requests: jobs, concurrency: 3, search: { source, page in
            try await client.search("故事", source: source, page: page)
        }, onResult: { outcome in await recorder.append(outcome); return true })
        let outcomes = await recorder.values
        XCTAssertEqual(outcomes.count, jobs.count)
        for outcome in outcomes {
            XCTAssertNil(outcome.failure)
            XCTAssertEqual(outcome.novels.first?.title, "故事" + outcome.sourceName)
        }
    }
    func testSearchPaginationReadsDifferentPagesAndStopsOnEmpty() async throws {
        var source = try source(); source.searchUrl = "/paged-search?page={{page}}&q={{key}}"
        let client = makeClient()
        let first = try await client.search("故事", source: source, page: 1)
        let second = try await client.search("故事", source: source, page: 2)
        let third = try await client.search("故事", source: source, page: 3)
        XCTAssertEqual(first.first?.title, "山海来信")
        XCTAssertEqual(second.first?.title, "第二本")
        XCTAssertEqual(second.first?.url.path, "/book/2")
        XCTAssertTrue(third.isEmpty)
    }
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
    func testBookAndChapterScriptContextSurvivesFreshClient() async throws {
        var source = try source()
        source.ruleContent?.content = "#content@text@js:book.name + '|' + chapter.title + '|' + chapter.index + '|' + result"
        let client = makeClient()
        let book = try await client.search("故事", source: source)[0]
        let novel = try await client.catalog(book, source: source)
        let fresh = makeClient()
        let content = try await fresh.chapter(novel.chapters[1], source: source)
        XCTAssertTrue(content.hasPrefix("山海来信|第二章|1|"), content)
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
        XCTAssertFalse(content.contains("第二天，天晴了。"), "Next chapter must not be appended as another content page")
        let saved = try JSONDecoder().decode(OnlineNovel.self, from: JSONEncoder().encode(novel))
        XCTAssertEqual(saved.chapters[0].nextChapterURL, novel.chapters[1].url)
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
        XCTAssertEqual(try script.evaluate("java.get('/missing',{}).code()", result: "", baseURL: url) as? Int, 404)
        XCTAssertEqual(try script.evaluate("java.connect('/missing').code()", result: "", baseURL: url) as? Int, 404)
        XCTAssertEqual(try script.evaluate("java.get('/js-search','{\"X-Reader\":\"Gavin\"}').code()", result: "", baseURL: url) as? Int, 200)
        XCTAssertEqual(try script.evaluate("String(java.connect('/api/chapter').raw().request().url())", result: "", baseURL: url) as? String, "https://fixture.example/api/chapter")
    }
    func testCachedExternalScriptAndLiteralSourceHeaders() throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let script = try SourceScript(configuration: config)
        let namespace = "https://cache-file-" + UUID().uuidString + ".example"
        let object: [String: Any] = ["bookSourceUrl": namespace, "header": "{'X-Reader':'Gavin'}"]
        try script.setJSONGlobal("source", json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        defer { SourceScriptCache.shared.delete(namespace, "remote-script:https://fixture.example/js-search") }
        let result = try script.evaluate("const first=java.importScript('https://fixture.example/js-search'); [first.includes('book'),java.cacheFile('https://fixture.example/js-search')===first,java.get('https://fixture.example/js-search',null).code()]", result: "", baseURL: URL(string: "https://fixture.example")!) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true); XCTAssertEqual(result?[1] as? Bool, true); XCTAssertEqual(result?[2] as? Int, 200)
    }
    func testDynamicHeadersAndNestedRequestKeepOuterQueryPageAndResult() throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let script = try SourceScript(configuration: config)
        let object: [String: String] = ["bookSourceUrl": "https://fixture.example", "header": "@js:JSON.stringify({'X-Reader':page===3&&key==='山海'?'Gavin':'wrong'})"]
        try script.setJSONGlobal("source", json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        let result = try script.evaluate("const before=result;const response=java.ajax('/js-search?value={{page+1}}');[response.includes('book'),page,key,result===before]", result: "outer", baseURL: URL(string: "https://fixture.example")!, globals: ["page":"3","key":"山海"]) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true); XCTAssertEqual(result?[1] as? Int, 3); XCTAssertEqual(result?[2] as? String, "山海"); XCTAssertEqual(result?[3] as? Bool, true)
    }
    func testSearchHeaderReceivesActualKeywordAndPage() async throws {
        var source = try source(); source.searchUrl = "/js-search"
        source.header = "@js:JSON.stringify({'X-Reader':key==='山海'&&page===3?'Gavin':'wrong'})"
        let books = try await makeClient().search("山海", source: source, page: 3)
        XCTAssertEqual(books.first?.title, "山海来信")
    }
    func testInteractiveVerificationRefetchAndResponseBody() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let script = try SourceScript(configuration: config, verificationHandler: { input in
            XCTAssertEqual(input.request.url?.host, "fixture.example")
            return SourceVerificationResult(text: input.imageCode ? "7319" : "<p>Verified page</p>", url: URL(string: "https://fixture.example/api/chapter")!, cookies: [])
        })
        let text = try await Task.detached {
            try script.evaluate("[java.startBrowserAwait('/login','Login',false).body(),JSON.parse(java.startBrowserAwait('/api/chapter','Login').body()).text,java.getVerificationCode('/code')].join('|')", result: "", baseURL: URL(string: "https://fixture.example")!) as? String
        }.value
        XCTAssertEqual(text, "<p>Verified page</p>|滚滚长江东逝水。|7319")
    }
    func testChapterCancellationStopsPendingInteractiveVerification() async throws {
        let entered = expectation(description: "Verification handler entered")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let client = SourceClient(configuration: config, verificationHandler: { _ in
            entered.fulfill(); try await Task.sleep(for: .seconds(20)); throw CancellationError()
        })
        var source = try source(); source.ruleContent?.content = "@js:java.getVerificationCode('/code')"
        let selected = source
        let task = Task { try await client.chapter(OnlineChapter(title: "Chapter", url: URL(string: "https://fixture.example/chapter/1")!), source: selected) }
        await fulfillment(of: [entered], timeout: 5)
        let start = ProcessInfo.processInfo.systemUptime; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled chapter succeeded") } catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testSourceAndRequestAuthenticationHeadersArePreserved() async throws {
        var source = try source()
        source.searchUrl = "/auth-search"
        source.header = #"{'Authorization':'Bearer fixture','Cookie':'sid=fixture'}"#
        let first = try await makeClient().search("故事", source: source)
        XCTAssertEqual(first.first?.title, "山海来信")
        source.header = nil
        source.searchUrl = #"/auth-search,{"headers":{"Authorization":"Bearer fixture","Cookie":"sid=fixture"}}"#
        let second = try await makeClient().search("故事", source: source)
        XCTAssertEqual(second.first?.title, "山海来信")
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
