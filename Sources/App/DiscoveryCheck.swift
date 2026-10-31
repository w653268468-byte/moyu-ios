#if DEBUG
import Foundation

@MainActor enum DiscoveryCheck {
    static func fixtureSource() throws -> BookSource {
        let object: [String: Any] = [
            "bookSourceName": "发现链路测试", "bookSourceUrl": "http://127.0.0.1:18765/discovery-source", "enabled": true, "enabledExplore": true,
            "exploreUrl": "排行榜\n周榜::/discovery-list?kind=week&page={{page}}\n分类\n玄幻::/discovery-list?kind=genre&page={{page}}\n编辑推荐\n今日精选::/discovery-list?kind=featured&page={{page}}",
            "searchUrl": "/source-search?q={{key}}", "ruleSearch": ["bookList": ".book", "name": "a@text", "bookUrl": "a@href"],
            "ruleExplore": ["bookList": ".book", "name": "a@text", "bookUrl": "a@href", "author": ".author@text", "intro": ".intro@text"],
            "ruleBookInfo": ["tocUrl": ".catalog@href"], "ruleToc": ["chapterList": "#list a", "chapterName": "text", "chapterUrl": "href"], "ruleContent": ["content": "#content@text"]
        ]
        return try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func run(directory: URL) async throws {
        let source = try fixtureSource(), client = SourceClient(), cache = DiscoveryCache(directory: directory)
        let model = DiscoveryModel(cache: cache)
        await model.load(source: source, client: client)
        guard !model.loading, model.failures.isEmpty, model.pool.count == 24, model.books.count == 12,
              model.sections.contains(where: { $0.lane == .rankings }), model.sections.contains(where: { $0.lane == .genres }) else { throw SourceError.message("发现首页分类、榜单或推荐未加载") }
        let first = model.books.map(\.id); model.batch = 1
        guard model.books.map(\.id) != first else { throw SourceError.message("每日推荐换一批没有变化") }
        let restored = DiscoveryModel(cache: cache); await restored.load(source: source, client: client)
        guard restored.books.map(\.id) == first, restored.updatedAt == model.updatedAt else { throw SourceError.message("每日推荐缓存重开没有保留") }
        let wrong = await cache.read(signature: "changed-rule")
        guard wrong == nil else { throw SourceError.message("规则变更后仍用了旧推荐缓存") }
        guard let ranking = model.sections.first(where: { $0.lane == .rankings }) else { throw SourceError.message("没有榜单") }
        let feed = DiscoveryFeedModel()
        await feed.load(source: source, category: ranking.category, client: client)
        guard feed.page == 1, feed.books.map(\.title) == ["周榜书1", "周榜书2"] else { throw SourceError.message("网站榜单顺序未保留") }
        await feed.load(source: source, category: ranking.category, client: client)
        guard feed.page == 2, feed.books.map(\.title) == ["周榜书1", "周榜书2", "周榜书3"] else { throw SourceError.message("榜单分页去重失败") }
        await feed.load(source: source, category: ranking.category, client: client, refresh: true)
        guard feed.page == 1, feed.books.count == 2 else { throw SourceError.message("刷新榜单未重新获取第一页") }
        let failed = DiscoveryFeedModel()
        await failed.load(source: source, category: ExploreCategory(title: "失败列表", url: "/discovery-failure"), client: client)
        guard failed.page == 0, failed.failure != nil, !failed.exhausted else { throw SourceError.message("失败的发现列表跳过了分页或无法重试") }
        let store = OnlineStore(directory: directory.appendingPathComponent("shelf"), client: client)
        try store.addSources([source])
        guard let book = restored.books.first else { throw SourceError.message("推荐为空") }
        let detail = try await client.catalog(book, source: source)
        try store.keep(detail)
        guard detail.chapters.count == 1, store.novels.contains(where: { $0.id == detail.id }) else { throw SourceError.message("发现书籍无法打开目录或加入书架") }
    }
}
#endif
