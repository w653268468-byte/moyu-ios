#if DEBUG
import Foundation

private actor HealthSearchServer {
    private var counts: [String: Int] = [:]
    func count(_ name: String) -> Int { counts[name, default: 0] }
    func render(_ request: URLRequest) -> (Data, URL) {
        let url = request.url!; counts[url.host ?? "", default: 0] += 1
        let html = url.path == "/chapter" ? "<div id='content'>保留的离线正文。</div>" : "<div class='book'><a href='/book'>book</a></div>"
        return (Data(html.utf8), url)
    }
}

@MainActor enum HealthVoiceCheck {
    static func run(directory: URL) async throws {
        let server = HealthSearchServer(), client = SourceClient(webRenderer: { request, _ in await server.render(request) })
        let online = OnlineStore(directory: directory, client: client), health = SourceHealthStore(directory: directory)
        func source(_ name: String) throws -> BookSource {
            try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: ["bookSourceName": name, "bookSourceUrl": "https://\(name).example", "searchUrl": "/search?key={{key}},{\"webView\":true}", "ruleSearch": ["bookList": ".book", "name": "a@text", "bookUrl": "a@href"], "ruleContent": ["content": "#content@text"]]))
        }
        let gone = try source("gone"), fast = try source("fast"), blocked = try source("blocked")
        try online.addSources([gone, fast, blocked])
        let chapterURL = URL(string: "https://gone.example/chapter")!
        let chapter = OnlineChapter(title: "第一章", url: chapterURL, requestTemplate: chapterURL.absoluteString + ",{\"webView\":true}")
        var book = OnlineNovel(title: "清理保留测试", url: URL(string: "https://gone.example/book")!, sourceID: gone.id)
        book.chapters = [chapter]; try online.keep(book)
        _ = try await online.chapter(chapter, sourceID: gone.id)
        for _ in 0..<2 { health.receive(gone, failure: "网站返回错误 HTTP 404", verifiedProbe: true); health.receive(blocked, failure: "网站返回错误 HTTP 403", verifiedProbe: true) }
        try health.cleanup(Set([gone.id, blocked.id]), online: online)
        guard !online.sources.contains(where: { $0.id == gone.id }), online.sources.contains(where: { $0.id == blocked.id }), online.novels.contains(where: { $0.id == book.id }) else { throw SourceError.message("书源清理误删登录受限源或书架记录") }
        let reloaded = OnlineStore(directory: directory, client: client)
        guard try await reloaded.chapter(chapter, sourceID: gone.id).contains("离线正文") else { throw SourceError.message("清理源后离线缓存丢失") }
        try health.restore(online: online)
        guard online.sources.contains(where: { $0.id == gone.id }), health.ledger.record(for: gone) == nil else { throw SourceError.message("清理备份不能恢复") }
        health.receive(gone, failure: "搜索超时"); health.receive(gone, failure: "搜索超时")
        health.receive(fast, failure: nil, latency: 5, hasResults: true)
        let model = SearchViewModel(health: health)
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw SourceError.message("智能搜索状态检查超时")
        }
        model.start("book", sources: [gone, fast], client: client)
        try await wait { !model.searching && model.completed == 1 }
        guard model.avoidedCount == 1, model.state.hits.count == 1, await server.count("gone.example") == 1 else { throw SourceError.message("搜索没有暂避重复失败源或未显示正常结果") }
        model.retryAvoided(client: client)
        try await wait { !model.searching && model.state.hits.count == 2 }
        guard model.avoidedCount == 0, health.ledger.record(for: gone)?.failures == 0 else { throw SourceError.message("强制重试未恢复正常书源") }

        let voices = NetworkVoiceStore(directory: directory), network = NetworkSpeechClient()
        let imported = try await network.importText("http://127.0.0.1:18765/tts-config.json")
        try voices.add(imported.engines); try voices.add(imported.engines)
        let restored = NetworkVoiceStore(directory: directory)
        guard restored.engines.count == 1 else { throw SourceError.message("网络音色保存重开或重复导入异常") }
        let engine = NetworkSpeechEngine(id: 999, name: "登录隔离检查", url: "http://127.0.0.1:18765/tts-audio?requireAuth=1&text={{java.encodeURI(speakText)}}", header: ##"{"X-Voice":"{{source.getLoginInfoMap().voice}}","X-Token":"{{source.getLoginInfoMap().token}}"}"##)
        try await network.setLoginInfo(#"{"voice":"native","token":"native-secret-value"}"#, engine: engine)
        let audio = try await network.render(engine, text: "原生请求头验证")
        guard audio.starts(with: Data("RIFF".utf8)), (try NetworkVoiceImport.export([engine])).range(of: Data("native-secret-value".utf8)) == nil else { throw SourceError.message("网络音色认证或配置导出隔离异常") }
        var other = engine; other.id = 998
        guard try await network.loginInfo(other) == "{}" else { throw SourceError.message("音色登录参数串源") }
        try await network.setLoginInfo("{}", engine: engine)
        let shared = NetworkSpeechEngine(id: 997, name: "共享脚本检查", url: "@js:sharedVoice(speakText)", jsLib: #"{"voice":"http://127.0.0.1:18765/tts-library.js"}"#)
        guard try await network.render(shared, text: "共享脚本音色").starts(with: Data("RIFF".utf8)) else { throw SourceError.message("网络音色共享脚本未生成有效音频") }
        try restored.remove(imported.engines[0].id)
        guard NetworkVoiceStore(directory: directory).engines.isEmpty else { throw SourceError.message("空音色列表重开异常") }
    }
}
#endif
