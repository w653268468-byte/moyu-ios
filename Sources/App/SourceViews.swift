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
