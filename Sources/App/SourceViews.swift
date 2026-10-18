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
    private var available: [BookSource] { online.sources.filter { $0.incompatibility == nil } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("用你自己的书源，找到下一段故事", systemImage: "globe.asia.australia")
                        .font(.headline).padding(.vertical, 6)
                    Text("兼容阅读 3.x 的部分 CSS 书源。先导入书源，再搜索书名或粘贴小说详情页网址。")
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
                Section("我的书源 · \(online.sources.count)") {
                    if online.sources.isEmpty {
                        ContentUnavailableView("还没有书源", systemImage: "link.badge.plus",
                                               description: Text("点击右上角加号，粘贴阅读 JSON 书源链接，或导入 JSON 文件。"))
                    }
                    ForEach(online.sources) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.bookSourceName).font(.headline)
                            Text(source.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let reason = source.incompatibility {
                                Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            } else {
                                Label("规则可识别 · 可用性需联网验证", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions {
                            Button("删除", role: .destructive) { online.deleteSource(source) }
                        }
                    }
                }
                Section("隐私与兼容性") {
                    Text("搜索和阅读会直接访问你选择的网站，对方可看到网络请求和搜索词。墨屿不提供内置书源，也不上传书架。")
                    Text("暂不支持 JS、XPath、JSONPath、POST、登录、验证码或付费内容解锁。书源失效和网站改版会导致解析失败。HTTP 书源采用未加密连接，建议优先使用 HTTPS。")
                    Button("清空已读章节缓存", role: .destructive) { online.clearCache() }
                }.font(.caption)
            }.navigationTitle("书源")
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { showImport = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel("导入阅读书源").disabled(online.locked)
                } }
                .sheet(isPresented: $showImport) { SourceImportView() }
                .sheet(item: $selection) { NovelDetailView(novel: $0) }
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
        Task {
            do { results = try await online.client.search(keyword, source: source) }
            catch { failure = error.localizedDescription }
            searching = false
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
                if busy { ProgressView(importStatus.isEmpty ? "正在解析书源…" : importStatus) }
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
                    Text("同地址书源会更新已有规则。不支持的书源也可保存，但不能用于搜索和解析。书源 JSON 只是规则配置，不会安装或执行其中的脚本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("导入书源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
                .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 5 * 1024 * 1024 else { throw SourceError.message("书源文件超过 5 MB。") }
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
        Task {
            var merged: [BookSource] = []
            var issues: [String] = []
            for (number, entry) in links.enumerated() {
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
                } catch { issues.append("链接 \(number + 1)：\(error.localizedDescription)") }
            }
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
                    }
                }
                if loading { ProgressView("正在获取章节目录…") }
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
                .fullScreenCover(item: $reading) { OnlineReaderView(novel: $0) }
        }
    }

    private func load() {
        guard !loading else { return }
        guard let source = online.sources.first(where: { $0.id == novel.sourceID }) else { failure = "找不到对应书源。"; return }
        loading = true; failure = nil
        saved = online.novels.contains { $0.id == novel.id && $0.sourceID == novel.sourceID }
        Task {
            do {
                let current = online.novels.first(where: { $0.id == novel.id && $0.sourceID == novel.sourceID }) ?? novel
                loaded = try await online.client.catalog(current, source: source)
            } catch { failure = error.localizedDescription }
            loading = false
        }
    }
}
