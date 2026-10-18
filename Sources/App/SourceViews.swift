import SwiftUI
import UniformTypeIdentifiers

struct SourceHubView: View {
    @EnvironmentObject private var online: OnlineStore
    @State private var showImport = false
    @State private var selectedSource = ""
    @State private var query = ""
    @State private var directURL = ""
    @State private var results: [OnlineNovel] = []
    @State private var selection: OnlineNovel?
    @State private var searching = false
    @State private var failure: String?
    @State private var didSearch = false
    @State private var searchTask: Task<Void, Never>?
    private var available: [BookSource] { online.sources.filter { $0.incompatibility == nil && $0.enabled != false } }

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
                        Picker("使用书源", selection: $selectedSource) {
                            ForEach(available) { Text($0.bookSourceName).tag($0.id) }
                        }.disabled(searching)
                        TextField("书名或作者", text: $query).submitLabel(.search).onSubmit { performSearch() }
                        Button { performSearch() } label: {
                            if searching { ProgressView("正在获取网页…") } else { Label("搜索", systemImage: "magnifyingglass") }
                        }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if searching { Button("取消搜索", role: .cancel) { searchTask?.cancel(); searching = false } }
                    }
                    if let source = available.first(where: { $0.id == selectedSource }), source.enabledExplore != false, !(source.exploreUrl ?? "").isEmpty {
                        Section("发现分类") {
                            NavigationLink("浏览所选书源的分类") { ExploreView(source: source) }
                        }
                    }
                    Section("通过小说链接打开") {
                        TextField("https://… 小说详情页或目录页", text: $directURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("解析目录") { openDirect() }.disabled(searching || directURL.isEmpty)
                        Text("链接需要与所选书源的网站匹配，无法自动识别任意网站。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure { Section("解析结果") { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if didSearch {
                    Section("搜索结果 · \(results.count)") {
                        if results.isEmpty && !searching { Text("没有结果，请检查书源、关键词或访问限制。").foregroundStyle(.secondary) }
                        ForEach(results) { novel in
                            Button { selection = novel } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(novel.title).foregroundStyle(.primary)
                                    if !novel.author.isEmpty { Text(novel.author).font(.caption).foregroundStyle(.secondary) }
                                    if !novel.intro.isEmpty { Text(novel.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Text("当前获取搜索结果的第一页，最多 100 本。").font(.caption).foregroundStyle(.secondary)
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
                .onDisappear { searchTask?.cancel() }
                .onAppear { chooseDefault() }
                .onChange(of: online.sources) { _, _ in chooseDefault() }
        }
    }

    private func chooseDefault() {
        if !available.contains(where: { $0.id == selectedSource }) { selectedSource = available.first?.id ?? "" }
    }

    private func performSearch() {
        guard !searching, let source = available.first(where: { $0.id == selectedSource }) else { return }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        searching = true; failure = nil; results = []; didSearch = true
        searchTask = Task {
            do {
                let found = try await online.client.search(keyword, source: source)
                try Task.checkCancellation(); results = found
            } catch { if !Task.isCancelled { failure = "搜索失败：" + error.localizedDescription } }
            if !Task.isCancelled { searching = false }
        }
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
    @State private var json = ""
    @State private var importingFile = false
    @State private var busy = false
    @State private var importStatus = ""
    @State private var importTask: Task<Void, Never>?
    @State private var preview: SourceImport?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("通过链接导入") {
                    Text("粘贴书源链接，每行一个，最多 20 个。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $link).frame(minHeight: 90)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("书源链接，每行一个")
                    Button("获取并预览书源") { fetchLink() }
                        .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("其他导入方式") {
                    Button("选择 JSON 文件", systemImage: "doc") { importingFile = true }.disabled(busy)
                    TextEditor(text: $json).frame(minHeight: 100).font(.caption.monospaced())
                        .accessibilityLabel("粘贴 JSON 书源文本")
                    Button("解析粘贴的 JSON") { parse(Data(json.utf8)) }.disabled(busy || json.isEmpty)
                }
                if busy {
                    ProgressView(importStatus.isEmpty ? "正在解析书源…" : importStatus)
                    Button("取消导入", role: .cancel) { importTask?.cancel(); busy = false; importStatus = "" }
                }
                if let failure { Section("提示") { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if let preview {
                    Section("预览 · \(preview.sources.count) 个书源") {
                        ForEach(preview.sources) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.bookSourceName)
                                Text(source.incompatibility ?? "规则可识别，导入后可测试搜索")
                                    .font(.caption).foregroundStyle(source.incompatibility == nil ? Color.secondary : Color.orange)
                            }
                        }
                        ForEach(Array(preview.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                        Button("确认导入 \(preview.sources.count) 个书源") {
                            do { try online.addSources(preview.sources); dismiss() }
                            catch { failure = error.localizedDescription }
                        }.disabled(preview.sources.isEmpty || busy)
                    }
                }
                Section {
                    Text("同地址书源会更新已有规则。不支持的书源也可保存，但不能用于搜索和解析。书源脚本在受限引擎中执行，部分 Java/Android 接口仍待实现；缺少接口会明确报错。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("导入书源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { importTask?.cancel(); dismiss() } } }
                .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
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

    private func fetchLink() {
        let links = link.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { return }
        guard links.count <= 20 else { failure = "一次最多处理 20 个书源链接，请分批导入。"; return }
        busy = true; failure = nil; preview = nil
        importTask = Task {
            var merged: [BookSource] = []
            var issues: [String] = []
            for (number, entry) in links.enumerated() {
                if Task.isCancelled { return }
                importStatus = "正在获取第 \(number + 1) / \(links.count) 个链接…"
                do {
                    var raw = entry
                    if raw.hasPrefix("legado://"), let components = URLComponents(string: raw),
                       let embedded = components.queryItems?.first(where: { $0.name == "src" })?.value { raw = embedded }
                    let url = try SourceClient.resolve(raw, base: URL(string: "https://example.com")!)
                    guard ["http", "https"].contains(URLComponents(string: raw)?.scheme?.lowercased() ?? "") else {
                        throw SourceError.message("请输入完整的 HTTP/HTTPS JSON 书源链接。")
                    }
                    let fetched = try await online.client.importURL(url)
                    issues += fetched.failures.map { "链接 \(number + 1)：\($0)" }
                    for source in fetched.sources {
                        if let index = merged.firstIndex(where: { $0.id == source.id }) { merged[index] = source }
                        else { merged.append(source) }
                    }
                } catch {
                    if Task.isCancelled { return }
                    issues.append("链接 \(number + 1)：\(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            if merged.isEmpty {
                failure = issues.isEmpty ? "没有读取到书源。" : issues.joined(separator: "\n")
            } else {
                preview = SourceImport(sources: merged, failures: issues)
            }
            importStatus = ""
            busy = false
        }
    }

    private func parse(_ data: Data) {
        busy = true; failure = nil; preview = nil
        Task {
            do { preview = try await Task.detached { try SourceImport.parse(data) }.value }
            catch { failure = error.localizedDescription }
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
