import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = DiscoveryModel()
    @AppStorage("reader.discovery.source") private var sourceID = ""
    @State private var lane = DiscoveryLane.daily
    @State private var importing = false
    @State private var selected: OnlineNovel?
    private var sources: [BookSource] {
        online.sources.filter { $0.enabled != false && $0.enabledExplore != false && !($0.exploreUrl ?? "").isEmpty }
    }
    private var source: BookSource? { sources.first(where: { $0.id == sourceID }) ?? sources.first }
    private var selectionKey: String { source.map(SourceHealthLedger.signature) ?? "" }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    hero
                    if let source {
                        sourcePicker(source)
                        Picker("发现频道", selection: $lane) {
                            ForEach(DiscoveryLane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("discovery.lane")
                        if model.loading { HStack { ProgressView(); Text("正在更新发现内容…").font(.caption).foregroundStyle(.secondary); Spacer(); Button("停止") { model.cancel() } } }
                        switch lane {
                        case .daily: daily(source)
                        case .rankings: categoryGrid(source, lane: .rankings)
                        case .genres: categoryGrid(source, lane: .genres)
                        }
                        if !model.failures.isEmpty { DisclosureGroup("\(model.failures.count) 项获取提示") { ForEach(model.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } } }
                    } else {
                        ContentUnavailableView("开启你的发现书城", systemImage: "sparkles", description: Text("导入带发现规则的书源，就能浏览它提供的推荐、榜单和分类。"))
                        Button("导入书源", systemImage: "plus.circle.fill") { importing = true }.buttonStyle(.borderedProminent)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 14)
            }.scrollBounceBehavior(.always, axes: .vertical).background(InterfaceAppearance.background)
                .navigationTitle("发现").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button { importing = true } label: { Image(systemName: "plus.circle") }.accessibilityLabel("导入发现书源") }
                .refreshable { if let source { await model.load(source: source, client: online.client, force: true) } }
                .task(id: selectionKey) { if let source { await model.load(source: source, client: online.client) } else { model.cancel() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, model.day != DiscoveryCatalog.dayKey(), let source {
                        Task { await model.load(source: source, client: online.client, force: true) }
                    }
                }
                .onDisappear { model.cancel() }
                .sheet(isPresented: $importing) { SourceImportView() }
                .sheet(item: $selected) { NovelDetailView(novel: $0) }
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Label("GAVIN · 发现故事", systemImage: "sparkles").font(.caption.weight(.semibold)); Spacer(); Text(Date(), format: .dateTime.month().day()).font(.caption) }.foregroundStyle(.secondary)
            Text(lane == .daily ? "今天，读点喜欢的" : lane == .rankings ? "看看大家在读什么" : "总有一种故事适合你")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text("每日推荐 · 真实榜单 · 按分类发现下一本").font(.subheadline).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color.accentColor.opacity(0.13), Color.orange.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
    }
    private func sourcePicker(_ source: BookSource) -> some View {
        HStack {
            Image(systemName: "globe.asia.australia").foregroundStyle(.tint)
            Picker("发现书源", selection: Binding(get: { source.id }, set: { sourceID = $0 })) { ForEach(sources) { Text($0.bookSourceName).tag($0.id) } }
                .accessibilityIdentifier("discovery.source")
            Spacer()
            Button { Task { await model.load(source: source, client: online.client, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.loading).accessibilityLabel("刷新发现").accessibilityIdentifier("discovery.refresh")
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 15))
    }
    private func daily(_ source: BookSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("每日推荐").font(.title3.bold()); Spacer(); Button("换一批", systemImage: "shuffle") { model.batch += 1 }.disabled(DiscoveryCatalog.dailyBooks(model.pool, day: model.day, limit: 13).count <= 12).accessibilityIdentifier("discovery.shuffle") }
            Text("从「\(source.bookSourceName)」的真实发现列表每日轮换，点击即可查看目录。")
                .font(.caption).foregroundStyle(.secondary)
            if let updated = model.updatedAt { Text("推荐日期 \(model.day) · 更新于 " + updated.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("discovery.updated") }
            if model.books.isEmpty && !model.loading {
                ContentUnavailableView("暂时没有推荐书籍", systemImage: "book.closed", description: Text("可下拉重试、选择其他书源，或直接浏览分类和榜单。"))
            }
            ForEach(model.books) { book in
                Button { selected = book } label: { DiscoveryBookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier("discovery.book.\(book.title)")
            }
        }
    }
    private func categoryGrid(_ source: BookSource, lane: DiscoveryLane) -> some View {
        let entries = model.sections.filter { $0.lane == lane }
        let headings = entries.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        return VStack(alignment: .leading, spacing: 16) {
            Text(lane == .rankings ? "网站榜单保持原始顺序，可进入后分页和刷新。" : "分类来自当前书源，可切换书源浏览更多题材。")
                .font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty && !model.loading {
                ContentUnavailableView(lane == .rankings ? "这个书源没有提供排行榜" : "这个书源没有提供分类", systemImage: lane == .rankings ? "chart.bar" : "square.grid.2x2", description: Text("换一个发现书源试试。"))
            }
            ForEach(headings, id: \.self) { group in
                Text(group).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], spacing: 12) {
                    ForEach(entries.filter { $0.group == group }) { entry in
                        NavigationLink { DiscoveryBooksView(source: source, entry: entry) } label: {
                            HStack { Image(systemName: lane == .rankings ? "chart.bar.fill" : "books.vertical").foregroundStyle(.tint); Text(entry.category.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary); Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                                .padding(14).frame(maxWidth: .infinity, minHeight: 60).background(.background, in: RoundedRectangle(cornerRadius: 15))
                        }.buttonStyle(.plain).accessibilityIdentifier("discovery.category.\(entry.category.title)")
                    }
                }
            }
        }
    }
}

private struct DiscoveryBookRow: View {
    let book: OnlineNovel
    var rank: Int? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            if let rank { Text(String(format: "%02d", rank)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(rank <= 3 ? Color.orange : Color.secondary).frame(width: 34).accessibilityLabel("第\(rank)名") }
            NovelCover(title: book.title, url: book.coverURL).frame(width: 65, height: 92).clipped()
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(book.author.isEmpty ? "作者未提供" : book.author).font(.caption).foregroundStyle(.secondary)
                if let kind = book.kind, !kind.isEmpty { Text(kind).font(.caption2).foregroundStyle(.tint).lineLimit(1) }
                if !book.intro.isEmpty { Text(book.intro).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let chapter = book.lastChapter, !chapter.isEmpty { Text("最新：" + chapter).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 17))
    }
}

struct DiscoveryBooksView: View {
    @EnvironmentObject private var online: OnlineStore
    let source: BookSource
    let entry: DiscoveryCategory
    @StateObject private var model = DiscoveryFeedModel()
    @State private var selected: OnlineNovel?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(source.bookSourceName + (entry.lane == .rankings ? " · 网站原榜单顺序" : " · " + entry.group)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.books.enumerated()), id: \.element.id) { index, book in
                    Button { selected = book } label: { DiscoveryBookRow(book: book, rank: entry.lane == .rankings ? index + 1 : nil) }
                        .buttonStyle(.plain).accessibilityIdentifier("discovery.result.\(book.title)")
                }
                if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if model.loading { ProgressView("正在获取第 \(model.page + 1) 页…"); Button("停止") { model.cancel() } }
                else if model.exhausted { Text(model.books.count >= 1000 ? "已展示 1000 本，可切换更具体的分类。" : "已经到底了").font(.caption).foregroundStyle(.secondary) }
                else { Button(model.failure != nil ? "重试当前页" : model.page == 0 ? "获取列表" : "加载下一页") { Task { await load() } }.buttonStyle(.bordered).accessibilityIdentifier("discovery.more") }
            }.padding(20)
        }.scrollBounceBehavior(.always, axes: .vertical).background(InterfaceAppearance.background)
            .navigationTitle(entry.category.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.loading).accessibilityLabel("刷新列表").accessibilityIdentifier("discovery.feed.refresh") }
            .refreshable { await load(refresh: true) }
            .task { if model.page == 0 { await load() } }
            .onDisappear { model.cancel() }
            .sheet(item: $selected) { NovelDetailView(novel: $0) }
    }
    private func load(refresh: Bool = false) async {
        guard online.sources.contains(where: { $0.id == source.id }) else { return }
        await model.load(source: source, category: entry.category, client: online.client, refresh: refresh)
    }
}
