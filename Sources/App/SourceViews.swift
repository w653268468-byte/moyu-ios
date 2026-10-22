import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    @State private var diagnostics: [String: SourceDiagnostics] = [:]
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
                    Button("导入实测示例书源", systemImage: "checkmark.circle") {
                        do {
                            guard let file = Bundle.main.url(forResource: "verified-sources", withExtension: "json") else { throw SourceError.message("缺少示例书源文件。") }
                            parse(try Data(contentsOf: file))
                        } catch { failure = error.localizedDescription }
                    }.disabled(busy).accessibilityIdentifier("source.import.samples")
                    Text("示例规则可离线导入；网站曾通过搜索、目录和正文测试，后续可用性仍取决于网站。")
                        .font(.caption).foregroundStyle(.secondary)
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
                                Text(diagnostics[source.id]?.full ?? "规则可识别，导入后可测试搜索")
                                    .font(.caption).foregroundStyle(diagnostics[source.id]?.full == nil ? Color.secondary : Color.orange)
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
                let checked = try await SourceDiagnostics.analyze(parsed.sources)
                try Task.checkCancellation()
                diagnostics = checked; preview = parsed; selected = Set(parsed.sources.map(\.id))
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
                let checked = try await SourceDiagnostics.analyze(parsed.sources)
                try Task.checkCancellation()
                diagnostics = checked; preview = parsed
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
    @AppStorage("reader.contentsDescending") private var contentsDescending = false
    @State private var switching = false
    private var activeNovel: OnlineNovel { loaded ?? novel }
    private var verificationURL: URL {
        if let source = online.sources.first(where: { $0.id == activeNovel.sourceID }), let url = BrowserSessions.loginURL(source) { return url }
        return activeNovel.url
    }

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
                        OfflineBookControls(book: loaded)
                    }
                }
                if loading {
                    ProgressView("正在获取章节目录…")
                    Button("取消获取", role: .cancel) { loadTask?.cancel(); loading = false }
                }
                if let failure {
                    Section("目录获取失败") {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                        Button("网页登录 / 验证", systemImage: "globe") { official = true }
                        Text("若网页要求登录或验证，请完成后关闭网页再重试；接口失效时需要更换书源。").font(.caption).foregroundStyle(.secondary)
                        Button("重新获取目录", systemImage: "arrow.clockwise") { load() }
                        Button("更换书源", systemImage: "arrow.triangle.swap") { switching = true }
                    }
                }
                if let loaded {
                    Section("章节目录") {
                        ForEach(ChapterOrder.indices(count: loaded.chapters.count, descending: contentsDescending), id: \.self) { index in
                            let chapter = loaded.chapters[index]
                            Button(chapter.title) { var book = loaded; book.chapterIndex = index; reading = book }
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }.safeAreaInset(edge: .top, spacing: 0) {
                if loaded != nil { ChapterOrderPicker(descending: $contentsDescending).padding(12).background(.bar) }
            }.navigationTitle("小说详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button(loading ? "更新中…" : "更新目录", systemImage: "arrow.clockwise") { load() }.disabled(loading) }
                }
                .task { load() }
                .onDisappear { loadTask?.cancel() }
                .fullScreenCover(item: $reading) { OnlineReaderView(novel: $0) }
                .sheet(isPresented: $official, onDismiss: { load() }) { OfficialWebView(url: verificationURL) }
                .sheet(isPresented: $switching) { SourceSwitchView(novel: activeNovel, chapterIndex: activeNovel.chapterIndex) { replacement in loaded = replacement; failure = nil; saved = true } }
        }
    }

    private func load() {
        guard !loading else { return }
        let novel = activeNovel
        let source = online.sources.first(where: { $0.id == novel.sourceID })
        guard let source else { failure = "对应书源已删除或旧版专用接口已移除。已缓存章节仍可从书架阅读；请导入新书源后重新搜索此书。"; return }
        loading = true; failure = nil
        saved = online.novels.contains { $0.id == novel.id && $0.sourceID == novel.sourceID }
        loadTask = Task {
            do {
                let current = online.novels.first(where: { $0.id == novel.id && $0.sourceID == novel.sourceID }) ?? novel
                var catalog = try await online.client.catalog(current, source: source)
                try Task.checkCancellation()
                catalog.catalogCheckedAt = Date(); catalog.lastChapter = catalog.chapters.last?.title
                if saved { try online.keepCatalog(catalog, checkedAt: Date()) }
                loaded = online.novels.first(where: { $0.id == catalog.id && $0.sourceID == catalog.sourceID }) ?? catalog
            } catch { if !Task.isCancelled { failure = "获取目录失败：" + error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }

}
