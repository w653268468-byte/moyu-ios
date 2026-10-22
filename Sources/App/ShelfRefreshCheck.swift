#if DEBUG
import Foundation

private actor ShelfRefreshServer {
    var counts: [String: Int] = [:]
    func count(_ path: String) -> Int { counts[path, default: 0] }
    func render(_ request: URLRequest) async throws -> (Data, URL) {
        let url = request.url!
        counts[url.path, default: 0] += 1
        try await Task.sleep(for: .milliseconds(url.path == "/removed" ? 250 : 80))
        if url.path == "/broken" { throw SourceError.message("测试目录服务暂时不可用") }
        let body = "<div id='list'>" + (1...4).map { "<a href='/chapter/\($0)'>第\($0)章</a>" }.joined() + "</div>"
        return (Data(body.utf8), url)
    }
}

@MainActor enum ShelfRefreshCheck {
    private static func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw SourceError.message("书架刷新检查超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run(directory: URL) async throws {
        let server = ShelfRefreshServer()
        let client = SourceClient(webRenderer: { request, _ in try await server.render(request) })
        let store = OnlineStore(directory: directory, client: client)
        let source = try JSONDecoder().decode(BookSource.self, from: Data(##"{"bookSourceName":"书架刷新测试","bookSourceUrl":"https://shelf-refresh.example","ruleToc":{"chapterList":"#list a","chapterName":"text","chapterUrl":"href"},"ruleContent":{"content":"#content@text"}}"##.utf8))
        try store.addSources([source])
        func book(_ path: String) -> OnlineNovel {
            let url = URL(string: "https://shelf-refresh.example/" + path)!
            var book = OnlineNovel(title: path, url: url, sourceID: source.id)
            book.requestTemplate = url.absoluteString + ",{\"webView\":true}"
            book.chapters = (1...3).map { OnlineChapter(title: "第\($0)章", url: URL(string: "https://shelf-refresh.example/chapter/\($0)")!) }
            return book
        }
        let good = book("good"), broken = book("broken")
        try store.keep(good); try store.keep(broken)
        store.position(good, index: 1, textOffset: 55)
        await store.refreshShelf()
        guard let updated = store.novels.first(where: { $0.id == good.id }), updated.chapters.count == 4,
              updated.chapterIndex == 1, updated.textOffset == 55, updated.lastChapter == "第4章",
              updated.unreadChapterIDs?.count == 1, store.refreshFailures.count == 1,
              store.novels.first(where: { $0.id == broken.id })?.chapters.count == 3 else { throw SourceError.message("整批刷新未保留失败小说目录、阅读进度或新章标记") }
        try store.flushProgress()
        let restored = OnlineStore(directory: directory, client: client)
        guard restored.novels.first(where: { $0.id == good.id })?.unreadChapterIDs?.count == 1 else { throw SourceError.message("新章状态重开后丢失") }
        store.position(updated, index: 3, textOffset: 0)
        guard store.novels.first(where: { $0.id == good.id })?.unreadChapterIDs?.isEmpty == true else { throw SourceError.message("阅读新增章节后未清除新章标记") }
        let removed = book("removed")
        try store.keep(removed)
        let deleting = Task { await store.refreshShelf() }
        try await wait { await server.count("/removed") > 0 }
        store.remove(removed)
        await deleting.value
        guard !store.novels.contains(where: { $0.id == removed.id }) else { throw SourceError.message("刷新回调重新加入了已移出的小说") }
        let oldCount = await server.count("/good")
        let stale = Task { await store.refreshShelf() }
        try await wait { await server.count("/good") > oldCount }
        var manual = store.novels.first(where: { $0.id == good.id })!
        manual.chapters.append(OnlineChapter(title: "第5章", url: URL(string: "https://shelf-refresh.example/chapter/5")!))
        try store.keepCatalog(manual, checkedAt: Date())
        await stale.value
        guard store.novels.first(where: { $0.id == good.id })?.chapters.count == 5 else { throw SourceError.message("旧刷新结果覆盖了较新的目录") }
        let cancelling = Task { await store.refreshShelf() }
        try await wait { store.refreshingShelf }
        store.cancelShelfRefresh()
        await cancelling.value
        guard !store.refreshingShelf, store.novels.first(where: { $0.id == good.id })?.chapters.count == 5 else { throw SourceError.message("取消刷新后仍有过期回调写入") }
        try store.flushProgress()
    }
}
#endif
