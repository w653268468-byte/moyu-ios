import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
private final class SearchViewModel: ObservableObject {
    @Published var state = SourceSearchState()
    @Published var searching = false
    @Published var didSearch = false
    @Published var completed = 0
    @Published var total = 0
    @Published var message: String?
    private(set) var keyword = ""
    private var sources: [BookSource] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var canLoadMore: Bool { !state.limitReached && sources.contains { state.failures[$0.id] == nil && !state.exhausted.contains($0.id) && (state.nextPages[$0.id] ?? 1) <= 10000 } }
    var failures: [SourceSearchFailure] { state.failures.values.sorted { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending } }

    func start(_ text: String, sources: [BookSource], client: SourceClient) {
        reset()
        keyword = text; self.sources = sources; didSearch = true
        batch(sources.map { SourceSearchRequest(source: $0, page: 1) }, client: client)
    }
    func more(client: SourceClient) {
        let jobs = sources.filter { state.failures[$0.id] == nil && !state.exhausted.contains($0.id) && (state.nextPages[$0.id] ?? 1) <= 10000 }
            .map { SourceSearchRequest(source: $0, page: state.nextPages[$0.id] ?? 1) }
        batch(jobs, client: client)
    }
    func retryFailures(client: SourceClient) {
        batch(sources.filter { state.failures[$0.id] != nil }.map { SourceSearchRequest(source: $0, page: state.nextPages[$0.id] ?? 1) }, client: client)
    }
    func cancel() { task?.cancel(); generation = UUID(); searching = false }
    func reset() {
        cancel(); state = SourceSearchState(); sources = []; keyword = ""; message = nil
        didSearch = false; completed = 0; total = 0
    }
    private func receive(_ outcome: SourceSearchOutcome, token: UUID) -> Bool {
        guard token == generation else { return false }
        state.receive(outcome); completed += 1
        if state.limitReached { message = "结果已达 5000 条，请缩小关键词或选择单个书源。" }
        return !state.limitReached
    }
    private func batch(_ jobs: [SourceSearchRequest], client: SourceClient) {
        guard !searching, !jobs.isEmpty, !state.limitReached else { return }
        let token = UUID(); generation = token
        let query = keyword
        searching = true; completed = 0; total = jobs.count; message = nil
        task = Task { [weak self] in
            do {
                try await SourceSearch.run(requests: jobs, search: { source, page in
                    try await client.search(query, source: source, page: page)
                }, onResult: { [weak self] outcome in
                    guard let self else { return false }
                    return await self.receive(outcome, token: token)
                })
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.generation == token else { return }
            self.searching = false
        }
    }
}

struct SourceHubView: View {
    @EnvironmentObject private var online: OnlineStore
    @State private var showImport = false
    @State private var selectedSource = ""
    @State private var query = ""
    @State private var directURL = ""
    @StateObject private var search = SearchViewModel()
    @State private var allSources = true
    @State private var available: [BookSource] = []
    @State private var selection: OnlineNovel?
    @State private var failure: String?
    private var searchable: [BookSource] {
        available.filter { !($0.searchUrl ?? "").isEmpty && !($0.ruleSearch?.bookList ?? "").isEmpty && !($0.ruleSearch?.name ?? "").isEmpty && !($0.ruleSearch?.bookUrl ?? "").isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("用你自己的书源，找到下一段故事", systemImage: "globe.asia.australia")
                        .font(.headline).padding(.vertical, 6)
                    Text("支持阅读 3.x 的 CSS、XPath、JSONPath 与常用 JavaScript 书源接口。先导入书源，再搜索书名或粘贴小说详情页网址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if online.locked { Section { Button("重新读取在线书架") { online.reload() } } }
                if !available.isEmpty {
                    Section("搜索小说") {
                        Toggle("搜索所有已启用书源", isOn: $allSources).disabled(search.searching)
                        Text(allSources ? "搜索范围：\(searchable.count) 个具备搜索规则的书源，结果陆续显示。" : "仅搜索下面选中的书源。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("目录／单源网站", selection: $selectedSource) {
                            ForEach(available) { Text($0.bookSourceName).tag($0.id) }
                        }.disabled(search.searching)
                        TextField("书名或作者", text: $query).submitLabel(.search).onSubmit { performSearch() }.disabled(search.searching)
                        Button { performSearch() } label: {
                            if search.searching { ProgressView("已完成 \(search.completed)/\(search.total) 个书源") } else { Label("搜索", systemImage: "magnifyingglass") }
                        }.disabled(search.searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchable.isEmpty)
                        if search.searching { Button("停止搜索，保留已找到的结果", role: .cancel) { search.cancel() } }
                    }
                    if let source = available.first(where: { $0.id == selectedSource }), source.enabledExplore != false, !(source.exploreUrl ?? "").isEmpty {
                        Section("发现分类") {
                            NavigationLink("浏览所选书源的分类") { ExploreView(source: source) }
                        }
                    }
                    Section("通过小说链接打开") {
                        TextField("https://… 小说详情页或目录页", text: $directURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("解析目录") { openDirect() }.disabled(search.searching || directURL.isEmpty)
                        Text("链接需要与所选书源的网站匹配，无法自动识别任意网站。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure { Section("解析结果") { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if let message = search.message { Section { Text(message).foregroundStyle(.orange) } }
                if search.didSearch {
                    Section("「\(search.keyword)」· \(search.state.hits.count) 个结果") {
                        if search.state.hits.isEmpty && !search.searching { Text("没有结果，请展开下面的失败详情，或调整关键词和搜索范围。").foregroundStyle(.secondary) }
                        ForEach(search.state.hits) { hit in
                            Button { selection = hit.novel } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.novel.title).foregroundStyle(.primary)
                                    Text(hit.sourceName).font(.caption2).foregroundStyle(.tint)
                                    if !hit.novel.author.isEmpty { Text(hit.novel.author).font(.caption).foregroundStyle(.secondary) }
                                    if !hit.novel.intro.isEmpty { Text(hit.novel.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if search.canLoadMore {
                            Button("加载更多结果") { search.more(client: online.client) }.disabled(search.searching)
                        } else if !search.searching && !search.state.hits.isEmpty && !search.state.limitReached {
                            Text("当前可用书源已无更多结果。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !search.failures.isEmpty {
                        Section {
                            DisclosureGroup("失败详情 · \(search.failures.count) 个书源") {
                                ForEach(search.failures) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.sourceName)
                                        Text(item.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                    }
                                }
                            }
                            Button("仅重试失败的书源") { search.retryFailures(client: online.client) }.disabled(search.searching)
                        }
                    }
                }
                Section("书源") {
                    Text("已导入 \(online.sources.count) 个书源。可到下方“书源”页进行多选删除、编辑、禁用和校验。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("隐私与兼容性") {
                    Text("搜索和阅读会直接访问你选择的网站，对方可看到网络请求和搜索词。Gavin不提供内置书源，也不上传书架。")
                    Text("Java/Android 脚本接口仍不完整，可在书源管理中打开网站登录或验证；不提供付费解锁。书源失效和网站改版会导致解析失败。HTTP 书源采用未加密连接，建议优先使用 HTTPS。")
                    Button("清空已读章节缓存", role: .destructive) { online.clearCache() }
                }.font(.caption)
            }.navigationTitle("找书")
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { showImport = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel("导入阅读书源").disabled(online.locked)
                } }
                .sheet(isPresented: $showImport) { SourceImportView() }
                .sheet(item: $selection) { NovelDetailView(novel: $0) }
                .onDisappear { search.cancel() }
                .onAppear { chooseDefault() }
                .onChange(of: online.sources) { _, _ in search.reset(); chooseDefault() }
                .onChange(of: allSources) { _, _ in search.reset() }
                .onChange(of: selectedSource) { _, _ in if !allSources { search.reset() } }
        }
    }

    private func chooseDefault() {
        available = online.sources.filter { $0.incompatibility == nil && $0.enabled != false }
        if !available.contains(where: { $0.id == selectedSource }) { selectedSource = available.first?.id ?? "" }
    }

    private func performSearch() {
        guard !search.searching else { return }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let sources = allSources ? searchable : searchable.filter { $0.id == selectedSource }
        guard !sources.isEmpty else { failure = "当前没有具备搜索规则的书源，请先导入或启用书源。"; return }
        failure = nil
        search.start(keyword, sources: sources, client: online.client)
    }

    private func openDirect() {
        do {
            guard let source = available.first(where: { $0.id == selectedSource }), let base = URL(string: source.bookSourceUrl) else { return }
            let url = try SourceClient.resolve(directURL, base: base)
            guard url.host?.lowercased() == base.host?.lowercased() else {
                throw SourceError.message("小说链接的域名与所选书源不同，请选择对应书源。")
            }
            failure = nil
            selection = OnlineNovel(title: "正在解析小说", url: url, sourceID: source.id)
        } catch { failure = error.localizedDescription }
    }
}

struct SourceImportView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var selected: Set<String> = []
    @State private var importingFile = false
    @State private var busy = false
    @State private var importStatus = ""
    @State private var importTask: Task<Void, Never>?
    @State private var preview: SourceImport?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴书源网址或 JSON") {
                    Text("网址或完整 JSON 均可粘贴，自动识别内容。一次最多获取 20 个网址；JSON 不按行数计算。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $link).frame(minHeight: 90)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("书源链接，每行一个")
                    Button("读取剪贴板", systemImage: "doc.on.clipboard") { link = UIPasteboard.general.string ?? "" }.disabled(busy)
                    Button("获取并预览书源") { importText(link) }
                        .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("其他导入方式") {
                    Button("选择 JSON 文件", systemImage: "doc") { importingFile = true }.disabled(busy)
                    Text("文件或粘贴 JSON 可直接导入，无需下载网址。若链接无法访问，可在 Safari 下载 JSON 后选择文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if busy {
                    ProgressView(importStatus.isEmpty ? "正在解析书源…" : importStatus)
                    Button("取消导入", role: .cancel) { importTask?.cancel(); busy = false; importStatus = "" }
                }
                if let failure { Section("提示") { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if let preview {
                    Section("预览 · \(preview.sources.count) 个书源") {
                        HStack {
                            Button("全选") { selected = Set(preview.sources.map(\.id)) }
                            Spacer()
                            Button("全不选") { selected = [] }
                        }.buttonStyle(.borderless)
                        ForEach(preview.sources) { source in
                            Toggle(isOn: Binding(get: { selected.contains(source.id) }, set: { if $0 { selected.insert(source.id) } else { selected.remove(source.id) } })) {
                              VStack(alignment: .leading, spacing: 5) {
                                Text(source.bookSourceName)
                                Text(source.incompatibility ?? "规则可识别，导入后可测试搜索")
                                    .font(.caption).foregroundStyle(source.incompatibility == nil ? Color.secondary : Color.orange)
                              }
                            }
                        }
                        ForEach(Array(preview.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }
                    if !preview.diagnostics.isEmpty {
                        Section { DisclosureGroup("获取详情") {
                            ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).textSelection(.enabled) }
                        } }
                    }
                }
                Section {
                    Text("同地址书源会更新已有规则。不支持的书源也可保存，但不能用于搜索和解析。书源脚本在受限引擎中执行，部分 Java/Android 接口仍待实现；缺少接口会明确报错。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(AppBuildIdentity.label).font(.caption2).foregroundStyle(.secondary)
                }
            }.navigationTitle("导入书源").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if let preview {
                        Button("确认导入 \(selected.count) 个书源") {
                            do { try online.addSources(preview.sources.filter { selected.contains($0.id) }); dismiss() }
                            catch { failure = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy)
                            .padding().frame(maxWidth: .infinity).background(.bar)
                    }
                }
                .onDisappear { importTask?.cancel() }
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-import-preview") {
                        link = "http://127.0.0.1:18765/source-start"
                        importText(link)
                    }
                    #endif
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { importTask?.cancel(); dismiss() } } }
                .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json, .plainText, .data]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= SourceImport.maximumBytes else { throw SourceError.message("书源文件超过 20 MB。") }
                        parse(try Data(contentsOf: url))
                    } catch { failure = error.localizedDescription }
                }
        }
    }

    private func importText(_ text: String) {
        guard !busy else { return }
        busy = true; failure = nil; preview = nil
        importStatus = "正在获取书源；大型合集最多等待 3 分钟，可随时取消…"
        importTask = Task {
            do {
                let parsed = try await online.client.importText(text)
                try Task.checkCancellation()
                preview = parsed; selected = Set(parsed.sources.map(\.id))
            } catch { if Task.isCancelled { return }; failure = error.localizedDescription }
            importStatus = ""
            busy = false
        }
    }

    private func parse(_ data: Data) {
        busy = true; failure = nil; preview = nil
        importTask = Task {
            do {
                let parsed = try await Task.detached { try SourceImport.parse(data) }.value
                try Task.checkCancellation()
                preview = parsed
                selected = Set(parsed.sources.map(\.id))
            } catch { if Task.isCancelled { return }; failure = error.localizedDescription }
            busy = false
        }
    }
}

struct NovelDetailView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    let novel: OnlineNovel
    @State private var loaded: OnlineNovel?
    @State private var failure: String?
    @State private var loading = false
    @State private var reading: OnlineNovel?
    @State private var saved = false
    @State private var official = false
    @State private var loadTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloading = false
    @State private var downloadStatus = ""
    @State private var confirmDownload = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(loaded?.title ?? novel.title).font(.title2.bold())
                    if let loaded {
                        if !loaded.author.isEmpty { Text(loaded.author).foregroundStyle(.secondary) }
                        if !loaded.intro.isEmpty { Text(loaded.intro).font(.subheadline) }
                        Text("\(loaded.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                        Button("继续阅读", systemImage: "book") {
                            var current = loaded
                            if let savedBook = online.novels.first(where: { $0.id == loaded.id && $0.sourceID == loaded.sourceID }) {
                                current.chapterIndex = min(savedBook.chapterIndex, max(0, current.chapters.count - 1))
                            }
                            reading = current
                        }
                        Button(saved ? "已加入书架" : "加入书架", systemImage: "plus") {
                            do { try online.keep(loaded); saved = true } catch { failure = error.localizedDescription }
                        }.disabled(saved)
                        Button("缓存全书供离线阅读", systemImage: "arrow.down.circle") { confirmDownload = true }
                            .disabled(downloading)
                    }
                }
                if loading {
                    ProgressView("正在获取章节目录…")
                    Button("取消获取", role: .cancel) { loadTask?.cancel(); loading = false }
                }
                if !downloadStatus.isEmpty { Text(downloadStatus).font(.caption).textSelection(.enabled) }
                if downloading { Button("停止缓存", role: .cancel) { downloadTask?.cancel() } }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red); Button("重新获取目录") { load() } }
                }
                if let loaded {
                    Section("章节目录") {
                        ForEach(Array(loaded.chapters.enumerated()), id: \.element.id) { index, chapter in
                            Button(chapter.title) { var book = loaded; book.chapterIndex = index; reading = book }
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }.navigationTitle("小说详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .task { load() }
                .onDisappear { loadTask?.cancel(); downloadTask?.cancel() }
                .confirmationDialog("缓存全书？", isPresented: $confirmDownload, titleVisibility: .visible) {
                    Button("开始缓存") { if let loaded { download(loaded) } }
                } message: { Text("会逐章下载并占用流量和存储空间；可随时停止，已缓存章节会保留。请保持此页面打开。") }
                .fullScreenCover(item: $reading) { OnlineReaderView(novel: $0) }
                .sheet(isPresented: $official) { OfficialWebView(url: novel.url) }
        }
    }

    private func load() {
        guard !loading else { return }
        let source = online.sources.first(where: { $0.id == novel.sourceID })
        guard let source else { failure = "对应书源已删除或旧版专用接口已移除。已缓存章节仍可从书架阅读；请导入新书源后重新搜索此书。"; return }
        loading = true; failure = nil
        saved = online.novels.contains { $0.id == novel.id && $0.sourceID == novel.sourceID }
        loadTask = Task {
            do {
                let current = online.novels.first(where: { $0.id == novel.id && $0.sourceID == novel.sourceID }) ?? novel
                loaded = try await online.client.catalog(current, source: source)
            } catch { if !Task.isCancelled { failure = "获取目录失败：" + error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }

    private func download(_ book: OnlineNovel) {
        guard !downloading else { return }
        downloading = true
        downloadTask = Task { @MainActor in
            var completed = 0
            defer { downloading = false }
            do {
                try online.keep(book); saved = true
                for chapter in book.chapters {
                    try Task.checkCancellation()
                    downloadStatus = "正在缓存 \(completed + 1)/\(book.chapters.count) · \(chapter.title)"
                    _ = try await online.chapter(chapter, sourceID: book.sourceID)
                    completed += 1
                    try await Task.sleep(for: .milliseconds(400))
                }
                downloadStatus = "已缓存全部 \(completed) 章，可在书架离线阅读。"
            } catch {
                downloadStatus = Task.isCancelled ? "已停止，保留已缓存的 \(completed) 章。" : "缓存到第 \(completed) 章后停止：\(error.localizedDescription)。已完成部分保留。"
            }
        }
    }
}
