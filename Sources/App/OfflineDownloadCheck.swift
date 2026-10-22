#if DEBUG
import Foundation

private actor OfflineCheckServer {
    var failSecond = true
    var offline = false
    var requests: [String: Int] = [:]
    func allowSecond() { failSecond = false }
    func disconnect() { offline = true }
    func count(_ path: String) -> Int { requests[path, default: 0] }
    func render(_ request: URLRequest) throws -> (Data, URL) {
        guard let url = request.url else { throw SourceError.message("Missing test URL") }
        requests[url.path, default: 0] += 1
        guard !offline else { throw SourceError.message("测试网络已断开") }
        if failSecond && url.path == "/2" { throw SourceError.message("测试第二章暂时失败") }
        return (Data(("<div id='content'>" + String(repeating: "离线下载测试正文", count: 50) + url.path + "</div>").utf8), url)
    }
}

@MainActor enum OfflineDownloadCheck {
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw SourceError.message("离线下载检查超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func run(directory: URL) async throws {
        let server = OfflineCheckServer()
        let client = SourceClient(webRenderer: { request, _ in try await server.render(request) })
        let store = OnlineStore(directory: directory, client: client)
        let source = try JSONDecoder().decode(BookSource.self, from: Data(##"{"bookSourceName":"离线测试","bookSourceUrl":"https://offline-check.example","ruleContent":{"content":"#content@text"}}"##.utf8))
        try store.addSources([source])
        var book = OnlineNovel(title: "下载测试", url: URL(string: "https://offline-check.example/book")!, sourceID: source.id)
        book.chapters = (1...3).map { value in
            let url = URL(string: "https://offline-check.example/\(value)")!
            return OnlineChapter(title: "第\(value)章", url: url, requestTemplate: url.absoluteString + ",{\"webView\":true}")
        }
        try store.keep(book)
        store.position(book, index: 1, textOffset: 17)
        store.startDownload(book)
        try await wait { (store.downloadState(book)?.completed ?? 0) == 1 }
        store.pauseDownload(book)
        try await Task.sleep(for: .milliseconds(500))
        guard store.downloadState(book)?.phase == .paused, await server.count("/2") == 0 else { throw SourceError.message("暂停后仍在下载") }
        store.startDownload(book)
        try await wait { store.downloadState(book)?.phase == .failed }
        guard store.downloadState(book)?.completed == 2, store.downloadState(book)?.failed == ["第2章"] else { throw SourceError.message("失败章节未独立保留或后续章节未继续下载") }
        await server.allowSecond()
        store.startDownload(book)
        try await wait { store.downloadState(book)?.phase == .completed }
        guard await server.count("/1") == 1, await server.count("/2") == 2, await server.count("/3") == 1 else { throw SourceError.message("继续或重试重复下载了已完成章节") }
        try store.flushProgress()
        await server.disconnect()
        let reloaded = OnlineStore(directory: directory, client: client)
        guard reloaded.novels.first?.chapterIndex == 1, reloaded.novels.first?.textOffset == 17, reloaded.downloadState(book)?.phase == .completed else { throw SourceError.message("下载覆盖了阅读进度或重开丢失下载状态") }
        for chapter in book.chapters {
            guard try await reloaded.chapter(chapter, sourceID: book.sourceID).contains("离线下载测试正文") else { throw SourceError.message("断网后无法读取缓存") }
        }
        guard await server.count("/1") == 1, await server.count("/2") == 2, await server.count("/3") == 1 else { throw SourceError.message("离线阅读错误地发起了网络请求") }
        var expanded = book
        expanded.chapters.append(OnlineChapter(title: "第4章", url: URL(string: "https://offline-check.example/4")!))
        try reloaded.keepCatalog(expanded)
        try await wait { reloaded.downloadState(expanded)?.completed == 3 && reloaded.downloadState(expanded)?.total == 4 }
        guard reloaded.downloadState(expanded)?.phase == .paused, reloaded.novels.first?.textOffset == 17 else { throw SourceError.message("新增章节后错误显示全书已下载或丢失阅读位置") }
        // A stale scan must not overwrite the new catalog's 3/4 cache state.
        await reloaded.refreshDownload(book)
        guard reloaded.downloadState(expanded)?.total == 4 else { throw SourceError.message("旧目录缓存统计覆盖了新目录") }
        reloaded.clearCache(); await reloaded.refreshDownload(expanded)
        guard reloaded.downloadState(expanded)?.completed == 0 else { throw SourceError.message("清理缓存后仍显示已下载") }
        try reloaded.flushProgress()
    }
}
#endif
