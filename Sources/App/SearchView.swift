import SwiftUI

@MainActor final class SearchPreferences: ObservableObject {
    @Published private(set) var history: BookSearchHistory
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.string(forKey: "reader.search.history").flatMap { $0.data(using: .utf8) }
        let saved = data.flatMap { try? JSONDecoder().decode(BookSearchHistory.self, from: $0) }
        history = BookSearchHistory(keywords: saved?.keywords ?? [])
    }
    func record(_ value: String) { history.record(value); save() }
    func remove(_ value: String) { history.remove(value); save() }
    func clear() { history.clear(); save() }
    func reload() {
        let value = defaults.string(forKey: "reader.search.history").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(BookSearchHistory.self, from: $0) }
        let fresh = BookSearchHistory(keywords: value?.keywords ?? [])
        if fresh != history { history = fresh }
    }
    private func save() { if let data = try? JSONEncoder().encode(history) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "reader.search.history") } }
}

@MainActor final class SearchViewModel: ObservableObject {
    @Published private(set) var state = SourceSearchState()
    @Published private(set) var searching = false
    @Published private(set) var didSearch = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var resultRevision = 0
    @Published private(set) var message: String?
    @Published private(set) var keyword = ""
    @Published private(set) var pendingCount = 0
    @Published private(set) var avoidedCount = 0
    private var avoided: [BookSource] = []
    private let health: SourceHealthStore?
    init(health: SourceHealthStore? = nil) { self.health = health }
    private var sources: [BookSource] = []
    private var pending: [SourceSearchRequest] = []
    private var generation = UUID()
    private var sessionID = UUID()
    private var task: Task<Void, Never>?
    private var concurrency = 6, timeout = 10.0
    private var activeSources: [BookSource] { let skipped = Set(avoided.map(\.id)); return sources.filter { !skipped.contains($0.id) } }
    var canLoadMore: Bool { !state.limitReached && activeSources.contains { state.failures[$0.id] == nil && !state.exhausted.contains($0.id) && (state.nextPages[$0.id] ?? 1) <= 10000 } }
    var failures: [SourceSearchFailure] { state.failures.values.sorted { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending } }

    func start(_ text: String, sources: [BookSource], client: SourceClient, concurrency: Int = 6, timeout: Double = 10, smartSources: Bool = true) {
        reset(); keyword = text; self.sources = sources; didSearch = true
        self.concurrency = concurrency; self.timeout = timeout
        let plan = smartSources ? health?.ledger.ordered(sources) : nil
        avoided = plan?.avoided ?? []; avoidedCount = avoided.count
        batch((plan?.active ?? sources).map { SourceSearchRequest(source: $0, page: 1) }, client: client)
    }
    func retryAvoided(client: SourceClient) {
        let retry = avoided; avoided = []; avoidedCount = 0
        batch(retry.map { SourceSearchRequest(source: $0, page: state.nextPages[$0.id] ?? 1) }, client: client)
    }
    func resume(client: SourceClient) { batch(pending, client: client) }
    func more(client: SourceClient) {
        batch(activeSources.filter { state.failures[$0.id] == nil && !state.exhausted.contains($0.id) && (state.nextPages[$0.id] ?? 1) <= 10000 }
            .map { SourceSearchRequest(source: $0, page: state.nextPages[$0.id] ?? 1) }, client: client)
    }
    func retry(client: SourceClient, sourceID: String? = nil) {
        batch(sources.filter { state.failures[$0.id] != nil && (sourceID == nil || $0.id == sourceID) }
            .map { SourceSearchRequest(source: $0, page: state.nextPages[$0.id] ?? 1) }, client: client)
    }
    func cancel() { task?.cancel(); generation = UUID(); searching = false; pendingCount = pending.count }
    func reset() {
        cancel(); sessionID = UUID(); state = SourceSearchState(); sources = []; pending = []; pendingCount = 0; keyword = ""; message = nil
        didSearch = false; completed = 0; total = 0; resultRevision += 1
        avoided = []; avoidedCount = 0
    }
    private func receive(_ outcome: SourceSearchOutcome, token: UUID) -> Bool {
        guard token == generation else { return false }
        if let source = sources.first(where: { $0.id == outcome.sourceID }) {
            health?.receive(source, failure: outcome.failure, latency: outcome.elapsedMilliseconds, hasResults: !outcome.novels.isEmpty)
        }
        pending.removeAll { $0.source.id == outcome.sourceID }; pendingCount = pending.count
        state.receive(outcome); completed += 1; resultRevision += 1
        if state.limitReached { message = "已达到 5000 条结果，可选择书源分组或使用精准筛选。" }
        return !state.limitReached
    }
    private func batch(_ jobs: [SourceSearchRequest], client: SourceClient) {
        guard !searching, !jobs.isEmpty, !state.limitReached else { return }
        let token = UUID(); generation = token
        let query = keyword, workers = concurrency, seconds = timeout, session = sessionID
        let scheduled = Set(jobs.map { $0.source.id })
        let remaining = pending.filter { !scheduled.contains($0.source.id) }
        searching = true; completed = 0; total = jobs.count; message = nil; pending = jobs + remaining; pendingCount = pending.count
        task = Task { [weak self] in
            do {
                try await SourceSearch.run(requests: jobs, concurrency: workers, timeoutSeconds: seconds, search: { source, page in
                    try await client.searchIndependent(query, source: source, page: page, sessionID: session)
                }, onResult: { [weak self] outcome in
                    guard let self else { return false }; return await self.receive(outcome, token: token)
                })
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.generation == token else { return }; self.searching = false
        }
    }
}

struct SourceHubView: View {
    @EnvironmentObject private var online: OnlineStore
    @StateObject private var search = SearchViewModel(health: .shared)
    @StateObject private var preferences = SearchPreferences()
    @AppStorage("reader.search.merge") private var merged = true
    @AppStorage("reader.search.exact") private var exact = false
    @AppStorage("reader.search.field") private var fieldRaw = BookSearchField.all.rawValue
    @AppStorage("reader.search.sort") private var sortRaw = BookSearchSort.relevance.rawValue
    @AppStorage("reader.search.concurrency") private var concurrency = 6
    @AppStorage("reader.search.timeout") private var timeout = 10.0
    @AppStorage("reader.search.smartSources") private var smartSources = true
    @AppStorage("reader.search.saveHistory") private var saveHistory = true
    @AppStorage("reader.search.scope") private var scopeRaw = "全部书源"
    @AppStorage("reader.search.customIDs") private var customIDs = "[]"
    @State private var query = ""
    @State private var selectedSource = ""
    @State private var directURL = ""
    @State private var showImport = false
    @State private var showSources = false
    @State private var showOptions = false
    @State private var clearHistory = false
    @State private var selection: OnlineNovel?
    @State private var selectedGroup: BookSearchGroup?
    @State private var available: [BookSource] = []
    @State private var presented: [BookSearchGroup] = []
    @State private var failure: String?
    @State private var preparedFixture = false
    @FocusState private var queryFocused: Bool
    private var searchable: [BookSource] { available.filter { online.searchReason($0) == nil } }
    private var scoped: [BookSource] {
        if scopeRaw == "全部书源" { return searchable }
        if scopeRaw.hasPrefix("分组：") { return searchable.filter { BookSearchPresentation.sourceGroups($0).contains(String(scopeRaw.dropFirst(3))) } }
        let ids = Set((try? JSONDecoder().decode([String].self, from: Data(customIDs.utf8))) ?? [])
        return searchable.filter { ids.contains($0.id) }
    }
    var body: some View {
        NavigationStack {
            List {
                searchBar
                if !search.didSearch { historySection }
                if search.didSearch { resultsSection }
                if search.avoidedCount > 0 {
                    Section { Button("本次暂避 \(search.avoidedCount) 个反复失败书源 · 仍要重试") { search.retryAvoided(client: online.client) }.disabled(search.searching).accessibilityIdentifier("search.retryAvoided") }
                }
                if !search.failures.isEmpty { failureSection }
                if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if let message = search.message { Section { Text(message).foregroundStyle(.orange) } }
                if !search.didSearch { toolsSection }
            }.scrollContentBackground(.hidden).background(InterfaceAppearance.background).navigationTitle("找书").scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("搜索设置")
                        Button { showImport = true } label: { Image(systemName: "plus.circle") }.accessibilityLabel("导入阅读书源")
                    }
                }
                .sheet(isPresented: $showImport) { SourceImportView() }
                .sheet(isPresented: $showSources) {
                    SearchSourcePicker(sources: available, scope: scopeRaw, customIDs: customIDs) { scope, ids in
                        scopeRaw = scope; customIDs = ids; search.reset()
                    }
                }
                .sheet(isPresented: $showOptions, onDismiss: { preferences.reload() }) { NavigationStack { SearchConfigurationView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showOptions = false } } } } }
                .sheet(item: $selection) { NovelDetailView(novel: $0) }
                .sheet(item: $selectedGroup) { SearchVariantsView(group: $0) }
                .confirmationDialog("清空搜索历史？", isPresented: $clearHistory, titleVisibility: .visible) { Button("清空", role: .destructive) { preferences.clear() } }
                .onDisappear { search.cancel() }
                .onAppear { preferences.reload(); refreshSources(); prepareSearchFixture() }
                .onChange(of: online.sources) { _, _ in search.reset(); refreshSources() }
                .task(id: "\(search.resultRevision)-\(fieldRaw)-\(exact)-\(merged)-\(sortRaw)") {
                    let hits = search.state.hits, term = search.keyword
                    let field = BookSearchField(rawValue: fieldRaw) ?? .all, sort = BookSearchSort(rawValue: sortRaw) ?? .relevance
                    let combine = merged, precise = exact
                    let result = await Task.detached { BookSearchPresentation.groups(hits, query: term, field: field, exact: precise, merged: combine, sort: sort) }.value
                    guard !Task.isCancelled else { return }; presented = result
                }
        }
    }
    private var searchBar: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索书名、作者", text: $query).submitLabel(.search).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().focused($queryFocused).onSubmit(performSearch).accessibilityIdentifier("search.query")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清空关键词").buttonStyle(.borderless) }
                Button("搜索", action: performSearch).buttonStyle(.borderedProminent).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("search.submit")
            }
            Button { showSources = true } label: { HStack { Label(scopeRaw, systemImage: "line.3.horizontal.decrease.circle"); Spacer(); Text("\(scoped.count) 个").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption) } }
                .accessibilityIdentifier("search.scope")
            if search.searching {
                ProgressView(value: Double(search.completed), total: Double(max(1, search.total)))
                HStack {
                    Text("已完成 \(search.completed)/\(search.total) · 已找到 \(search.state.hits.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("停止") { search.cancel() }.buttonStyle(.borderless).accessibilityIdentifier("search.stop")
                }
            } else if search.didSearch && search.pendingCount > 0 {
                Button("继续未完成的 \(search.pendingCount) 个书源") { search.resume(client: online.client) }
            }
            if searchable.isEmpty { Text("先导入书源，即可按书名或作者搜索。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var historySection: some View {
        Section {
            if preferences.history.keywords.isEmpty { ContentUnavailableView("找一本想读的书", systemImage: "book", description: Text("支持全书源、分组和指定书源搜索。")) }
            else {
                HStack { Text("搜索历史").font(.headline); Spacer(); Button("清空") { clearHistory = true }.buttonStyle(.borderless) }
                ForEach(preferences.history.keywords, id: \.self) { word in
                    Button { query = word; performSearch() } label: { Label(word, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                        .accessibilityIdentifier("search.history." + word)
                        .swipeActions { Button("删除", role: .destructive) { preferences.remove(word) } }
                }
            }
        }
    }
    private var resultsSection: some View {
        Section {
            HStack {
                Text("\(presented.count) 本 · \(search.state.hits.count) 条书源结果").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("search.count")
                Spacer()
                Menu {
                    Picker("排序", selection: $sortRaw) { ForEach(BookSearchSort.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) } }
                    Toggle("同书名同作者合并", isOn: $merged)
                    Toggle("精准匹配", isOn: $exact)
                    Picker("筛选", selection: $fieldRaw) { ForEach(BookSearchField.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) } }
                } label: { Label(BookSearchSort(rawValue: sortRaw)?.name ?? "排序", systemImage: "arrow.up.arrow.down") }.accessibilityLabel("结果排序与筛选")
            }
            if presented.isEmpty && !search.searching {
                ContentUnavailableView("没有找到匹配的书", systemImage: "magnifyingglass", description: Text(search.state.hits.isEmpty ? "可更换关键词、搜索分组或重试失败书源。" : "已有返回结果，可关闭精准匹配或更改书名/作者筛选。"))
            }
            ForEach(presented) { group in
                Button {
                    if group.variants.count == 1 { selection = group.representative.novel } else { selectedGroup = group }
                } label: { SearchBookRow(group: group, onShelf: isOnShelf(group.representative.novel)) }
                    .accessibilityIdentifier("search.result." + group.representative.novel.title)
            }
            if !search.searching && search.pendingCount == 0 && search.canLoadMore { Button("加载下一页") { search.more(client: online.client) }.accessibilityIdentifier("search.more") }
        } header: { Text("「\(search.keyword)」的搜索结果") }
    }
    private var failureSection: some View {
        Section {
            DisclosureGroup("\(search.failures.count) 个书源未完成，可单独重试") {
                ForEach(search.failures) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(item.sourceName); Spacer(); Button("重试") { search.retry(client: online.client, sourceID: item.id) }.buttonStyle(.borderless).disabled(search.searching) }
                        Text(item.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Button("重试全部失败书源") { search.retry(client: online.client) }.disabled(search.searching)
        }
    }
    private var toolsSection: some View {
        Section {
            DisclosureGroup("小说链接与书源发现") {
                Picker("网站", selection: $selectedSource) { ForEach(available) { Text($0.bookSourceName).tag($0.id) } }
                if let source = available.first(where: { $0.id == selectedSource }), source.enabledExplore != false, !(source.exploreUrl ?? "").isEmpty { NavigationLink("发现分类") { ExploreView(source: source) } }
                TextField("粘贴小说详情页或目录链接", text: $directURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("打开小说链接", action: openDirect).disabled(directURL.isEmpty)
            }
        }
    }
    private func refreshSources() {
        available = online.sources.filter { $0.enabled != false }
        if !available.contains(where: { $0.id == selectedSource }) { selectedSource = available.first?.id ?? "" }
    }
    private func performSearch() {
        let keyword = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !keyword.isEmpty else { return }
        guard !scoped.isEmpty else { failure = "当前范围没有可搜索书源，请选择其他分组或导入书源。"; return }
        query = keyword; failure = nil; queryFocused = false
        if saveHistory { preferences.record(keyword) }
        search.start(keyword, sources: scoped, client: online.client, concurrency: concurrency, timeout: timeout, smartSources: smartSources)
    }
    private func isOnShelf(_ book: OnlineNovel) -> Bool {
        online.novels.contains { $0.id == book.id || (!$0.author.isEmpty && BookSearchPresentation.normalized($0.title) == BookSearchPresentation.normalized(book.title) && BookSearchPresentation.normalized($0.author) == BookSearchPresentation.normalized(book.author)) }
    }
    private func openDirect() {
        do {
            guard let source = available.first(where: { $0.id == selectedSource }), let base = URL(string: source.bookSourceUrl) else { return }
            let url = try SourceClient.resolve(directURL, base: base)
            guard url.host?.lowercased() == base.host?.lowercased() else { throw SourceError.message("请先选择小说链接对应的网站。") }
            selection = OnlineNovel(title: "正在解析小说", url: url, sourceID: source.id)
        } catch { failure = error.localizedDescription }
    }
    private func prepareSearchFixture() {
        #if DEBUG
        guard !preparedFixture, ProcessInfo.processInfo.arguments.contains("--ui-search-fixture") else { return }
        preparedFixture = true
        Task {
            do {
                let imported = try await online.client.importText("http://127.0.0.1:18765/search-test-sources")
                try online.addSources(imported.sources); refreshSources()
                scopeRaw = "分组：搜索测试"; query = "公版"; exact = false; merged = true; fieldRaw = "all"; sortRaw = "relevance"
                if ProcessInfo.processInfo.arguments.contains("--ui-search-auto") { try await Task.sleep(for: .milliseconds(300)); performSearch() }
            } catch { failure = error.localizedDescription }
        }
        #endif
    }
}

private struct SearchBookRow: View {
    let group: BookSearchGroup
    let onShelf: Bool
    var body: some View {
        let book = group.representative.novel
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: book.coverURL) { image in image.resizable().scaledToFill() } placeholder: {
                ZStack { Color.accentColor.opacity(0.1); Image(systemName: "book.closed").foregroundStyle(.tint) }
            }.frame(width: 55, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(book.title).font(.headline).foregroundStyle(.primary); if onShelf { Text("已在书架").font(.caption2).foregroundStyle(.tint) } }
                Text(book.author.isEmpty ? "作者未知" : book.author).font(.subheadline).foregroundStyle(.secondary)
                let metadata = [book.kind, book.wordCountLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let chapter = book.lastChapter, !chapter.isEmpty { Text("最新：" + chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !book.intro.isEmpty { Text(book.intro).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(group.sourceCount > 1 ? "\(group.sourceCount) 个书源 · 点击选择" : group.representative.sourceName).font(.caption2).foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
    }
}

private struct SearchVariantsView: View {
    let group: BookSearchGroup
    @Environment(\.dismiss) private var dismiss
    @State private var selection: OnlineNovel?
    var body: some View {
        NavigationStack {
            List(group.variants) { hit in
                Button { selection = hit.novel } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(hit.sourceName).foregroundStyle(.primary); Spacer(); if let ms = hit.elapsedMilliseconds { Text("搜索 \(ms) ms").font(.caption).foregroundStyle(.secondary) } }
                        if let chapter = hit.novel.lastChapter, !chapter.isEmpty { Text(chapter).font(.caption).foregroundStyle(.secondary) }
                        Text(hit.novel.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle(group.representative.novel.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(item: $selection) { NovelDetailView(novel: $0) }
        }
    }
}

private struct SearchSourcePicker: View {
    @EnvironmentObject private var online: OnlineStore
    let sources: [BookSource]
    let onApply: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: String
    @State private var group = ""
    @State private var filter = ""
    @State private var selected: Set<String>
    init(sources: [BookSource], scope: String, customIDs: String, onApply: @escaping (String, String) -> Void) {
        self.sources = sources; self.onApply = onApply
        _mode = State(initialValue: scope == "全部书源" ? "全部" : scope.hasPrefix("分组：") ? "分组" : "指定")
        _group = State(initialValue: scope.hasPrefix("分组：") ? String(scope.dropFirst(3)) : "")
        _selected = State(initialValue: Set((try? JSONDecoder().decode([String].self, from: Data(customIDs.utf8))) ?? []))
    }
    private var groups: [String] { Array(Set(sources.flatMap { BookSearchPresentation.sourceGroups($0) })).sorted() }
    private var visible: [BookSource] {
        sources.filter { source in
            (mode != "分组" || BookSearchPresentation.sourceGroups(source).contains(group)) &&
            (filter.isEmpty || [source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup ?? ""].contains { $0.localizedCaseInsensitiveContains(filter) })
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("搜索范围", selection: $mode) { Text("全部").tag("全部"); Text("分组").tag("分组"); Text("指定书源").tag("指定") }.pickerStyle(.segmented)
                    if mode == "分组" { Picker("分组", selection: $group) { Text("请选择").tag(""); ForEach(groups, id: \.self) { Text($0).tag($0) } } }
                    if mode == "指定" { HStack { Button("全选当前列表") { selected.formUnion(visible.filter { online.searchReason($0) == nil }.map(\.id)) }; Spacer(); Button("清空") { selected = [] } }.buttonStyle(.borderless) }
                }
                Section("\(visible.count) 个书源") {
                    ForEach(visible) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.bookSourceName)
                                if let reason = online.searchReason(source) { Text(reason).font(.caption).foregroundStyle(.orange) }
                                else if let group = source.bookSourceGroup { Text(group).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if mode == "指定" { Toggle("选择", isOn: Binding(get: { selected.contains(source.id) }, set: { if $0 { selected.insert(source.id) } else { selected.remove(source.id) } })).labelsHidden().disabled(online.searchReason(source) != nil) }
                        }
                    }
                }
            }.searchable(text: $filter, prompt: "名称、分组或网址")
                .navigationTitle("搜索范围").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") {
                        let scope = mode == "全部" ? "全部书源" : mode == "分组" ? "分组：" + group : "指定书源"
                        let data = (try? JSONEncoder().encode(selected.sorted())) ?? Data("[]".utf8)
                        onApply(scope, String(decoding: data, as: UTF8.self)); dismiss()
                    }.disabled(mode == "分组" && group.isEmpty || mode == "指定" && selected.isEmpty) }
                }
        }
    }
}
