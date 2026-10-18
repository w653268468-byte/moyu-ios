import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var online: OnlineStore
    let source: BookSource
    @State private var categories: [ExploreCategory] = []
    @State private var failure: String?
    @State private var loading = true
    var body: some View {
        List {
            if loading { ProgressView("正在读取分类…") }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(categories) { category in
                if category.isHeading { Text(category.title).font(.headline).foregroundStyle(.secondary) }
                else { NavigationLink(category.title) { ExploreBooksView(source: source, category: category) } }
            }
            if !loading && categories.isEmpty && failure == nil { Text("这个书源没有配置发现分类。").foregroundStyle(.secondary) }
        }.navigationTitle(source.bookSourceName).navigationBarTitleDisplayMode(.inline)
            .task {
                do { categories = try await online.client.categories(source: source) }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
                loading = false
            }
    }
}

private struct ExploreBooksView: View {
    @EnvironmentObject private var online: OnlineStore
    let source: BookSource
    let category: ExploreCategory
    @State private var novels: [OnlineNovel] = []
    @State private var page = 0
    @State private var loading = false
    @State private var exhausted = false
    @State private var failure: String?
    @State private var selected: OnlineNovel?
    @State private var task: Task<Void, Never>?
    @State private var loadID = UUID()
    var body: some View {
        List {
            ForEach(novels) { novel in
                Button { selected = novel } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(novel.title).foregroundStyle(.primary)
                        if !novel.author.isEmpty { Text(novel.author).font(.caption).foregroundStyle(.secondary) }
                        if !novel.intro.isEmpty { Text(novel.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if loading { ProgressView("正在获取第 \(page + 1) 页…"); Button("取消") { task?.cancel(); loadID = UUID(); loading = false } }
            else if exhausted { Text("当前分类没有更多结果。").foregroundStyle(.secondary) }
            else { Button(page == 0 ? "获取列表" : "加载下一页") { load() } }
        }.navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
            .onAppear { if page == 0 && !loading { load() } }
            .onDisappear { task?.cancel(); loadID = UUID(); loading = false }
            .sheet(item: $selected) { NovelDetailView(novel: $0) }
    }
    private func load() {
        guard !loading else { return }
        loading = true; failure = nil
        loadID = UUID()
        let token = loadID
        task = Task {
            do {
                guard online.sources.contains(where: { $0.id == source.id }) else { throw SourceError.message("书源已被删除，请返回选择其他书源。") }
                let found = try await online.client.explore(category, page: page + 1, source: source)
                try Task.checkCancellation()
                guard token == loadID else { return }
                let additions = found.filter { novel in !novels.contains(where: { $0.id == novel.id }) }
                novels += additions; page += 1
                exhausted = found.isEmpty || additions.isEmpty
            } catch { if !Task.isCancelled && token == loadID { failure = error.localizedDescription } }
            if token == loadID { loading = false }
        }
    }
}
