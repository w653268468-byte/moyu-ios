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
    @State private var pendingProbeIDs: Set<String> = []
    @State private var lastProbeIDs: Set<String> = []
    @State private var resumeCleanup = false
    @State private var sourceGroup = "全部分组"
    @AppStorage("reader.sourceSort") private var sourceSort = "原始顺序"
    @State private var editingGroup = false
    @State private var groupName = ""
    private let filters = ["全部", "已启用", "已禁用", "规则不兼容", "校验失败", "已确认失效", "暂避搜索"]
    private var removable: [BookSource] { online.sources.filter { health.ledger.record(for: $0)?.removable == true } }

    private var visible: [BookSource] {
        let matching = online.sources.filter { source in
            let matches = query.isEmpty || [source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            let groupMatches = sourceGroup == "全部分组" || (sourceGroup == "未分组" ? BookSearchPresentation.sourceGroups(source).isEmpty : BookSearchPresentation.sourceGroups(source).contains(sourceGroup))
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
            return matches && groupMatches && state
        }
        if sourceSort == "健康优先" { return health.ledger.ordered(matching, avoidingFailures: false).active }
        if sourceSort == "响应速度" {
            let latency = Dictionary(matching.map { ($0.id, health.ledger.record(for: $0)?.latency ?? Int.max) }, uniquingKeysWith: { first, _ in first })
            return matching.enumerated().sorted {
                let a = latency[$0.element.id] ?? Int.max, b = latency[$1.element.id] ?? Int.max
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
        }
        if sourceSort == "名称" { return matching.sorted { $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending } }
        return matching
    }
    private var sourceGroups: [String] { Array(Set(online.sources.flatMap { BookSearchPresentation.sourceGroups($0) })).sorted() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛选", selection: $filter) { ForEach(filters, id: \.self) { Text($0).tag($0) } }
                    Picker("书源分组", selection: $sourceGroup) {
                        Text("全部分组").tag("全部分组"); Text("未分组").tag("未分组")
                        ForEach(sourceGroups.filter { $0 != "全部分组" && $0 != "未分组" }, id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("sources.group")
                    Picker("排序", selection: $sourceSort) {
                        ForEach(["原始顺序", "健康优先", "响应速度", "名称"], id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("sources.sort")
                    Text("共 \(online.sources.count) 个 · 当前显示 \(visible.count) 个")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("一键检测并清理失效书源", systemImage: "sparkles") { probe(online.sources, offerCleanup: true) }
                        .disabled(checking || online.sources.isEmpty).accessibilityIdentifier("sources.cleanup.scan")
                    Button("检测失效源（快速）", systemImage: "waveform.path.ecg") { probe(visible) }.disabled(checking).accessibilityIdentifier("sources.probe")
                    if !pendingProbeIDs.isEmpty {
                        Button("继续未完成检测 · \(pendingProbeIDs.count) 个", systemImage: "play.circle") {
                            probe(online.sources.filter { pendingProbeIDs.contains($0.id) }, offerCleanup: resumeCleanup, continuing: true)
                        }.disabled(checking).accessibilityIdentifier("sources.probe.resume")
                    }
                    let retryIDs = failed.intersection(lastProbeIDs)
                    if !retryIDs.isEmpty {
                        Button("仅重试检测失败 · \(retryIDs.count) 个", systemImage: "arrow.clockwise") {
                            probe(online.sources.filter { retryIDs.contains($0.id) }, offerCleanup: resumeCleanup)
                        }.disabled(checking).accessibilityIdentifier("sources.probe.retry")
                    }
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
                        ProgressView(checkProgress).accessibilityIdentifier("sources.probe.progress")
                        Button("停止校验", role: .cancel) { checkTask?.cancel() }.accessibilityIdentifier("sources.probe.stop")
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
                            Button("完整体检当前列表", systemImage: "checkmark.shield") { check(visible) }.disabled(checking)
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
                                Button("设置分组") { groupName = ""; editingGroup = true }
                                Button("校验") { check(online.sources.filter { selection.contains($0.id) }) }
                                Button("删除所选", role: .destructive) { askDelete(selection) }
                            }.disabled(selection.isEmpty)
                        }
                    }
                }
                .sheet(isPresented: $importing) { SourceImportView() }
                .alert("设置所选书源分组", isPresented: $editingGroup) {
                    TextField("分组名称（留空移除分组）", text: $groupName)
                    Button("取消", role: .cancel) { }
                    Button("保存分组") {
                        do { try online.setSourceGroup(selection, group: groupName); sourceGroup = "全部分组" }
                        catch { online.errorMessage = "分组保存失败：" + error.localizedDescription }
                    }
                } message: { Text("统一替换已选 \(selection.count) 个书源的分组。多个分组可用英文逗号分隔。") }
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
    private func probe(_ sources: [BookSource], offerCleanup: Bool = false, continuing: Bool = false) {
        guard !checking else { return }
        checking = true; probeCompleted = 0; probeSummary = nil; checkProgress = "准备检测…"
        let client = online.client, health = health
        let lookup = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pendingProbeIDs = Set(lookup.keys)
        if continuing { lastProbeIDs.formUnion(pendingProbeIDs) } else { lastProbeIDs = pendingProbeIDs }
        resumeCleanup = offerCleanup
        let started = Date(), total = lookup.count
        checkTask = Task {
            defer { checking = false; checkProgress = "" }
            do {
                try await SourceSearch.probe(sources: sources, client: client, onUnconfirmedGone: { source, message in
                    await health.receive(source, failure: message, verifiedProbe: true)
                }, onResult: { outcome in
                    await MainActor.run {
                        guard !Task.isCancelled, let source = lookup[outcome.sourceID] else { return false }
                        health.receive(source, failure: outcome.failure, latency: outcome.elapsedMilliseconds, hasResults: !outcome.novels.isEmpty, verifiedProbe: true)
                        pendingProbeIDs.remove(source.id)
                        probeCompleted += 1
                        let remaining = max(0, total - probeCompleted)
                        let seconds = Int(ceil(Date().timeIntervalSince(started) * Double(remaining) / Double(max(1, probeCompleted))))
                        let estimate = seconds >= 60 ? "约 \((seconds + 59) / 60) 分钟" : "约 \(seconds) 秒"
                        checkProgress = "\(probeCompleted)/\(total) · 剩余\(estimate) · \(outcome.sourceName)"
                        checks[source.id] = outcome.failure ?? (outcome.novels.isEmpty ? "接口已响应，无匹配结果；不算失效" : "搜索接口可用")
                        if outcome.failure != nil { failed.insert(source.id) } else { failed.remove(source.id) }
                        return true
                    }
                })
                try Task.checkCancellation()
                probeSummary = "检测完成 \(probeCompleted) 个 · 已复核失效 \(removable.count) 个。超时、登录或解析失败不会自动删除。"
                if offerCleanup && !removable.isEmpty { cleanupPending = true }
            } catch is CancellationError {
                probeSummary = "检测已停止，已完成 \(probeCompleted)/\(sources.count) 个；结果已保留，可继续清理已确认失效源。"
            } catch {
                if Task.isCancelled {
                    probeSummary = "检测已停止，已完成 \(probeCompleted)/\(sources.count) 个；结果已保留。"
                } else { online.errorMessage = "检测未完成：" + error.localizedDescription }
            }
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
                    let worker = await online.client.isolatedWorker(reloadIgnoringCache: true)
                    let report = try await SourceValidator.validate(source, client: worker, progress: { progress in
                        await MainActor.run {
                            let stage = progress.stage == "search" ? "搜索" : progress.stage == "catalog" ? "目录" : "正文"
                            checks[source.id] = "正在检查\(stage)" + (progress.chapterTitle.map { " · " + $0 } ?? "")
                            checkProgress = "\(number + 1)/\(sources.count) · \(source.bookSourceName) · \(stage)"
                        }
                    })
                    checks[source.id] = "搜索、目录、正文通过 · \(report.chapters) 章 · \(report.chapterTitle) \(report.characters) 字"
                    failed.remove(source.id)
                    health.receive(source, failure: nil, hasResults: true, fullValidation: true)
                } catch {
                    if Task.isCancelled || error is CancellationError { break }
                    let stage = checks[source.id]?.replacingOccurrences(of: "正在检查", with: "") ?? "规则"
                    checks[source.id] = "\(stage)未通过：\(error.localizedDescription)"; failed.insert(source.id)
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
