import SwiftUI
import UniformTypeIdentifiers

struct JSONExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SourceManagerView: View {
    @EnvironmentObject private var online: OnlineStore
    @ObservedObject private var health = SourceHealthStore.shared
    @State private var cleanupPending = false
    @State private var probeCompleted = 0
    @State private var query = ""
    @State private var filter = "全部"
    @State private var selection: Set<String> = []
    @State private var selecting = false
    @State private var importing = false
    @State private var editing: BookSource?
    @State private var authorizing: BookSource?
    @State private var pendingDelete: Set<String> = []
    @State private var confirmDelete = false
    @State private var export: JSONExport?
    @State private var exporting = false
    @State private var checks: [String: String] = [:]
    @State private var failed: Set<String> = []
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    @State private var checkProgress = ""
    @State private var probeSummary: String?
    private let filters = ["全部", "已启用", "已禁用", "规则不兼容", "校验失败", "已确认失效", "暂避搜索"]
    private var removable: [BookSource] { online.sources.filter { health.ledger.record(for: $0)?.removable == true } }

    private var visible: [BookSource] {
        online.sources.filter { source in
            let matches = query.isEmpty || [source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            let state: Bool
            switch filter {
            case "已启用": state = source.enabled != false
            case "已禁用": state = source.enabled == false
            case "规则不兼容": state = online.sourceReason(source) != nil
            case "校验失败": state = failed.contains(source.id) || health.ledger.record(for: source)?.kind != nil
            case "已确认失效": state = health.ledger.record(for: source)?.removable == true
            case "暂避搜索": state = health.ledger.record(for: source)?.removable == true || (health.ledger.record(for: source)?.cooldownUntil ?? .distantPast) > Date()
            default: state = true
            }
            return matches && state
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛选", selection: $filter) { ForEach(filters, id: \.self) { Text($0).tag($0) } }
                    Text("共 \(online.sources.count) 个 · 当前显示 \(visible.count) 个")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("一键检测并清理失效书源", systemImage: "sparkles") { probe(online.sources, offerCleanup: true) }
                        .disabled(checking || online.sources.isEmpty).accessibilityIdentifier("sources.cleanup.scan")
                    Button("检测失效源（快速）", systemImage: "waveform.path.ecg") { probe(visible) }.disabled(checking).accessibilityIdentifier("sources.probe")
                    Button("一键清理已确认失效 · \(removable.count) 个", systemImage: "trash", role: .destructive) { cleanupPending = true }
                        .disabled(removable.isEmpty || checking).accessibilityIdentifier("sources.cleanup")
                    if let message = health.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    if let probeSummary { Text(probeSummary).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sources.probe.summary") }
                    if selecting {
                        HStack {
                            Button("全选当前列表") { selection.formUnion(visible.map(\.id)) }
                            Spacer()
                            Button("取消全选") { selection = [] }
                        }
                    }
                }
                if checking {
                    Section {
                        ProgressView(checkProgress)
                        Button("停止校验", role: .cancel) { checkTask?.cancel() }
                    }
                }
                if visible.isEmpty {
                    ContentUnavailableView("没有匹配的书源", systemImage: "line.3.horizontal.decrease.circle", description: Text("可更换筛选条件或点击右上角导入。"))
                }
                ForEach(visible) { source in
                    HStack(alignment: .top, spacing: 12) {
                        if selecting {
                            Button {
                                if selection.contains(source.id) { selection.remove(source.id) } else { selection.insert(source.id) }
                            } label: { Image(systemName: selection.contains(source.id) ? "checkmark.circle.fill" : "circle").font(.title2) }
                                .buttonStyle(.borderless).accessibilityLabel("选择\(source.bookSourceName)")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(source.bookSourceName).font(.headline)
                                if source.enabled == false { Text("已禁用").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let group = source.bookSourceGroup, !group.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary) }
                            Text(source.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let reason = online.sourceReason(source) { Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(3) }
                            else { Text("规则可识别 · 尚不代表网站可用").font(.caption).foregroundStyle(.secondary) }
                            if let check = checks[source.id] { Text(check).font(.caption).textSelection(.enabled) }
                            else if let record = health.ledger.record(for: source) {
                                Text(record.kind.map { $0.name + " · " + record.message } ?? (record.lastValidated != nil ? "完整链路通过" : record.hasResults ? "搜索已取得结果" : "搜索接口已响应，暂无匹配结果"))
                                    .font(.caption).foregroundStyle(record.kind == nil ? Color.secondary : Color.orange).lineLimit(3)
                                if let latency = record.latency { Text("近期响应约 \(latency) ms").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if !selecting {
                                HStack(spacing: 22) {
                                    Button("编辑") { editing = source }
                                    Button("登录") { authorizing = source }
                                    Button(source.enabled == false ? "启用" : "禁用") { online.setEnabled([source.id], enabled: source.enabled == false) }
                                    Button("校验") { check([source]) }.disabled(checking)
                                    Button("删除", role: .destructive) { askDelete([source.id]) }
                                }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }.padding(.vertical, 5)
                    .swipeActions {
                        Button("删除", role: .destructive) { askDelete([source.id]) }
                        Button("编辑") { editing = source }.tint(.blue)
                    }
                }
                Section {
                    Text("校验优先使用作者的测试词，再尝试通用书名，优先同名书；读取目录，从目录前 100 项选择编号正文章节，最多检查三个候选章节；没有编号时需手动核实及至少 200 字正文。每个书源最多等待 45 秒。校验失败不一定代表永久失效。删除书源保留书架记录和已缓存章节。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(InterfaceAppearance.background).navigationTitle("书源管理")
                .searchable(text: $query, prompt: "名称、网址或分组")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(selecting ? "完成" : "多选") { selecting.toggle(); selection = [] } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("导入书源", systemImage: "plus") { importing = true }
                            Button("导出全部", systemImage: "square.and.arrow.up") { exportSources(online.sources) }
                            Button("校验当前列表", systemImage: "checkmark.shield") { check(visible) }.disabled(checking)
                            Button("重新尝试当前书源") { health.reset(Set(visible.map(\.id))) }
                            Button("恢复上次清理", systemImage: "arrow.uturn.backward") {
                                do { try health.restore(online: online); checks = [:]; failed = []; filter = "全部" } catch { online.errorMessage = error.localizedDescription }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("书源操作").accessibilityIdentifier("sources.actions")
                        Button { importing = true } label: { Image(systemName: "plus.circle.fill") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        if selecting {
                            Text("已选 \(selection.count)").font(.caption)
                            Spacer()
                            Menu("操作") {
                                Button("启用") { online.setEnabled(selection, enabled: true) }
                                Button("禁用") { online.setEnabled(selection, enabled: false) }
                                Button("导出") { exportSources(online.sources.filter { selection.contains($0.id) }) }
                                Button("校验") { check(online.sources.filter { selection.contains($0.id) }) }
                                Button("删除所选", role: .destructive) { askDelete(selection) }
                            }.disabled(selection.isEmpty)
                        }
                    }
                }
                .sheet(isPresented: $importing) { SourceImportView() }
                .confirmationDialog("清理 \(removable.count) 个已复核失效的书源？", isPresented: $cleanupPending, titleVisibility: .visible) {
                    Button("备份并删除失效源", role: .destructive) {
                        do { try health.cleanup(Set(removable.map(\.id)), online: online) } catch { online.errorMessage = error.localizedDescription }
                    }
                } message: { Text("仅清理地址两次返回 404/410 的当前规则。超时、登录、限流或规则兼容问题不自动删除；清理前保存备份，可从右上角恢复。书架和已缓存章节保留。") }
                .sheet(item: $authorizing) { source in
                    if let url = BrowserSessions.loginURL(source) { OfficialWebView(url: url) }
                }
                .sheet(item: $editing) { SourceEditorView(source: $0) }
                .confirmationDialog("删除 \(pendingDelete.count) 个书源？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除书源", role: .destructive) { online.deleteSources(pendingDelete); selection.subtract(pendingDelete) }
                } message: { Text("书架记录和已缓存章节会保留，尚未缓存的章节需要重新导入对应书源才能读取。") }
                .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "Gavin书源.json") { result in
                    if case .failure(let error) = result { online.errorMessage = error.localizedDescription }
                }
                .onDisappear { checkTask?.cancel() }
        }
    }

    private func askDelete(_ ids: Set<String>) { pendingDelete = ids; confirmDelete = !ids.isEmpty }
    private func probe(_ sources: [BookSource], offerCleanup: Bool = false) {
        guard !checking else { return }
        checking = true; probeCompleted = 0; probeSummary = nil; let client = online.client, health = health, session = UUID()
        let lookup = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        checkTask = Task {
            defer { checking = false; checkProgress = "" }
            do {
                try await SourceSearch.run(requests: sources.map { SourceSearchRequest(source: $0, page: 1) }, concurrency: 6, timeoutSeconds: 10, search: { source, page in
                    do { return try await client.searchIndependent("三国演义", source: source, page: page, sessionID: session) }
                    catch {
                        try Task.checkCancellation()
                        guard SourceFailureKind.classify(error.localizedDescription) == .endpointGone else { throw error }
                        await health.receive(source, failure: error.localizedDescription, verifiedProbe: true)
                        try await Task.sleep(for: .milliseconds(300))
                        return try await client.searchIndependent("三国演义", source: source, page: page, sessionID: UUID())
                    }
                }, onResult: { outcome in
                    await MainActor.run {
                        guard !Task.isCancelled, let source = lookup[outcome.sourceID] else { return false }
                        health.receive(source, failure: outcome.failure, latency: outcome.elapsedMilliseconds, hasResults: !outcome.novels.isEmpty, verifiedProbe: true)
                        probeCompleted += 1; checkProgress = "\(probeCompleted)/\(sources.count) · \(outcome.sourceName)"
                        checks[source.id] = outcome.failure ?? (outcome.novels.isEmpty ? "接口已响应，无匹配结果；不算失效" : "搜索接口可用")
                        if outcome.failure != nil { failed.insert(source.id) } else { failed.remove(source.id) }
                        return true
                    }
                })
                try Task.checkCancellation()
                probeSummary = "检测完成 \(probeCompleted) 个 · 已复核失效 \(removable.count) 个。超时、登录或解析失败不会自动删除。"
                if offerCleanup && !removable.isEmpty { cleanupPending = true }
            } catch { if !Task.isCancelled { online.errorMessage = error.localizedDescription } }
        }
    }
    private func exportSources(_ sources: [BookSource]) {
        do { export = JSONExport(data: try SourceImport.export(sources)); exporting = true }
        catch { online.errorMessage = error.localizedDescription }
    }
    private func check(_ sources: [BookSource]) {
        guard !checking else { return }
        checking = true
        checkTask = Task { @MainActor in
            defer { checking = false; checkProgress = "" }
            for (number, source) in sources.enumerated() {
                if Task.isCancelled { break }
                checkProgress = "\(number + 1)/\(sources.count) · \(source.bookSourceName)"
                do {
                    if let reason = online.sourceReason(source) { throw SourceError.message("规则不兼容：\(reason)") }
                    let report = try await SourceValidator.validate(source, client: online.client)
                    checks[source.id] = "搜索、目录、正文通过 · \(report.chapters) 章 · \(report.chapterTitle) \(report.characters) 字"
                    failed.remove(source.id)
                    health.receive(source, failure: nil, hasResults: true, fullValidation: true)
                } catch {
                    if Task.isCancelled { break }
                    checks[source.id] = "校验失败：\(error.localizedDescription)"; failed.insert(source.id)
                    health.receive(source, failure: error.localizedDescription)
                }
            }
        }
    }
}

private struct SourceEditorView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    @State private var text = ""
    @State private var failure: String?
    init(source: BookSource) { self.source = source }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("编辑完整 JSON 规则，保留书源网址以更新现有书源。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                TextEditor(text: $text).font(.system(.caption, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let failure { Text(failure).foregroundStyle(.red).font(.caption).padding() }
            }.navigationTitle("编辑书源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do {
                            let parsed = try SourceImport.parse(Data(text.utf8))
                            guard parsed.sources.count == 1, parsed.failures.isEmpty, let updated = parsed.sources.first else { throw SourceError.message("请保留一个有效书源对象。") }
                            try online.replaceSource(source.id, with: updated); dismiss()
                        } catch { failure = error.localizedDescription }
                    } }
                }.onAppear { text = (try? String(data: SourceImport.export([source]), encoding: .utf8)) ?? "" }
        }
    }
}
