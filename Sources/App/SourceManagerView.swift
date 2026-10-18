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
    @State private var query = ""
    @State private var filter = "全部"
    @State private var selection: Set<String> = []
    @State private var selecting = false
    @State private var importing = false
    @State private var editing: BookSource?
    @State private var pendingDelete: Set<String> = []
    @State private var confirmDelete = false
    @State private var export: JSONExport?
    @State private var exporting = false
    @State private var checks: [String: String] = [:]
    @State private var failed: Set<String> = []
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    @State private var checkProgress = ""
    private let filters = ["全部", "已启用", "已禁用", "规则不兼容", "校验失败"]

    private var visible: [BookSource] {
        online.sources.filter { source in
            let matches = query.isEmpty || [source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            let state: Bool
            switch filter {
            case "已启用": state = source.enabled != false
            case "已禁用": state = source.enabled == false
            case "规则不兼容": state = source.incompatibility != nil
            case "校验失败": state = failed.contains(source.id)
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
                            if let reason = source.incompatibility { Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(3) }
                            else { Text("规则可识别 · 尚不代表网站可用").font(.caption).foregroundStyle(.secondary) }
                            if let check = checks[source.id] { Text(check).font(.caption).textSelection(.enabled) }
                            if !selecting {
                                HStack(spacing: 22) {
                                    Button("编辑") { editing = source }
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
                    Text("校验会尝试搜索“三国”，并读取第一本结果的目录和首章；无结果会单独提示。校验失败不一定代表书源永久失效。删除书源保留书架记录和已缓存章节。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("书源管理")
                .searchable(text: $query, prompt: "名称、网址或分组")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(selecting ? "完成" : "多选") { selecting.toggle(); selection = [] } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("导入书源", systemImage: "plus") { importing = true }
                            Button("导出全部", systemImage: "square.and.arrow.up") { exportSources(online.sources) }
                            Button("校验当前列表", systemImage: "checkmark.shield") { check(visible) }.disabled(checking)
                        } label: { Image(systemName: "ellipsis.circle") }
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
                .sheet(item: $editing) { SourceEditorView(source: $0) }
                .confirmationDialog("删除 \(pendingDelete.count) 个书源？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除书源", role: .destructive) { online.deleteSources(pendingDelete); selection.subtract(pendingDelete) }
                } message: { Text("书架记录和已缓存章节会保留，尚未缓存的章节需要重新导入对应书源才能读取。") }
                .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "墨屿书源.json") { result in
                    if case .failure(let error) = result { online.errorMessage = error.localizedDescription }
                }
                .onDisappear { checkTask?.cancel() }
        }
    }

    private func askDelete(_ ids: Set<String>) { pendingDelete = ids; confirmDelete = !ids.isEmpty }
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
                    if let reason = source.incompatibility { throw SourceError.message("规则不兼容：\(reason)") }
                    let books = try await online.client.search("三国", source: source)
                    guard let first = books.first else { checks[source.id] = "搜索请求完成，但“三国”无结果；未验证目录和正文。"; failed.remove(source.id); continue }
                    let novel = try await online.client.catalog(first, source: source)
                    guard let firstChapter = novel.chapters.first else { throw SourceError.message("目录为空") }
                    let text = try await online.client.chapter(firstChapter, source: source)
                    checks[source.id] = "搜索、目录、首章通过 · \(novel.chapters.count) 章 · 首章 \(text.count) 字"
                    failed.remove(source.id)
                } catch {
                    if Task.isCancelled { break }
                    checks[source.id] = "校验失败：\(error.localizedDescription)"; failed.insert(source.id)
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
