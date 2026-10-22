import SwiftUI
import UniformTypeIdentifiers

struct ReplacementRulesView: View {
    @ObservedObject private var store = ReadingToolsStore.shared
    @State private var query = ""
    @State private var editing: TextReplacementRule?
    @State private var importing = false
    @State private var chooseFile = false
    @State private var initialData: Data?
    @State private var exporting = false
    @State private var exported: JSONExport?
    @State private var failure: String?
    private var filtered: [TextReplacementRule] { store.rules.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.group ?? "").localizedCaseInsensitiveContains(query) || $0.pattern.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section {
                Text("按顺序处理正文或标题，支持普通文字、正则表达式和安卓阅读替换规则 JSON。原书与章节缓存保留，关闭规则可恢复原文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("规则 · \(store.rules.count) 条") {
                ForEach(filtered) { rule in
                    HStack {
                        Button { editing = rule } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.name).font(.headline).foregroundStyle(.primary)
                                Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                if let group = rule.group, !group.isEmpty { Text(group).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Toggle("启用 \(rule.name)", isOn: Binding(get: { rule.isEnabled }, set: { store.setEnabled(rule, $0) })).labelsHidden()
                    }.swipeActions { Button("删除", role: .destructive) { do { try store.commit(store.rules.filter { $0.id != rule.id }) } catch { failure = error.localizedDescription } } }
                        .moveDisabled(!query.isEmpty)
                }.onMove { offsets, destination in
                    guard query.isEmpty else { return }
                    var rules = store.rules; rules.move(fromOffsets: offsets, toOffset: destination)
                    for index in rules.indices { rules[index].order = index }
                    do { try store.commit(rules) } catch { failure = error.localizedDescription }
                }
                if store.rules.isEmpty { Text("添加一条规则，或导入已有的规则集合。").foregroundStyle(.secondary) }
            }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.red) }
        }.searchable(text: $query, prompt: "规则名称、分组或匹配内容")
            .navigationTitle("替换净化").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { editing = TextReplacementRule() } label: { Image(systemName: "plus") }.accessibilityLabel("添加净化规则") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("粘贴 JSON 或网址") { initialData = nil; importing = true }
                        Button("导入 JSON 文件") { chooseFile = true }
                        Button("导出替换规则") { do { exported = JSONExport(data: try ReplacementImport.export(store.rules)); exporting = true } catch { failure = error.localizedDescription } }
                        EditButton()
                        Button("重新读取规则") { store.reload() }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("净化规则导入与管理")
                }
            }
            .sheet(item: $editing) { ReplacementRuleEditor(rule: $0) }
            .sheet(isPresented: $importing) { ReplacementImportView(initialData: initialData) }
            .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.json, .plainText]) { result in
                if case .success(let url) = result {
                    Task {
                        do {
                            let data = try await Task.detached {
                                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5 * 1024 * 1024 else { throw SourceError.message("规则文件超过 5 MB。") }
                                return try Data(contentsOf: url, options: .mappedIfSafe)
                            }.value
                            initialData = data; importing = true
                        } catch { failure = error.localizedDescription }
                    }
                } else if case .failure(let error) = result { failure = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exported, contentType: .json, defaultFilename: "Gavin替换规则.json") { if case .failure(let error) = $0 { failure = error.localizedDescription } }
            .alert("替换净化", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("知道了") { failure = nil } } message: { Text(failure ?? "") }
    }
}

private struct ReplacementRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: TextReplacementRule
    @State private var sample = "ORIGINAL reader text.\n这里可以粘贴一段正文，检查替换效果。"
    @State private var preview = ""
    @State private var failure: String?
    @State private var previewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewBook = "示例小说"
    @State private var previewTitle = false
    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("规则名称", text: $rule.name).accessibilityIdentifier("replace.name")
                    TextField("分组（可选）", text: Binding(get: { rule.group ?? "" }, set: { rule.group = $0.isEmpty ? nil : $0 }))
                    Text("匹配内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rule.pattern).font(.system(.body, design: .monospaced)).frame(minHeight: 70).accessibilityIdentifier("replace.pattern")
                    Text("替换为（留空表示删除）").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rule.replacement).font(.system(.body, design: .monospaced)).frame(minHeight: 70).accessibilityIdentifier("replace.replacement")
                    Toggle("使用正则表达式", isOn: $rule.isRegex)
                    Toggle("启用这条规则", isOn: $rule.isEnabled)
                }
                Section("作用范围") {
                    Toggle("正文", isOn: $rule.scopeContent)
                    Toggle("章节标题", isOn: $rule.scopeTitle)
                    TextField("指定书名或书源网址（留空为全部）", text: Binding(get: { rule.scope ?? "" }, set: { rule.scope = $0.isEmpty ? nil : $0 }))
                    TextField("排除的书名或书源网址", text: Binding(get: { rule.excludeScope ?? "" }, set: { rule.excludeScope = $0.isEmpty ? nil : $0 }))
                    Text("范围可填写多个完整书名或书源网址，与安卓阅读的范围字段对应。").font(.caption).foregroundStyle(.secondary)
                }
                Section("先试一段文字") {
                    TextField("预览使用的书名", text: $previewBook)
                    Toggle("按章节标题预览", isOn: $previewTitle)
                    TextEditor(text: $sample).frame(minHeight: 100).accessibilityIdentifier("replace.sample")
                    Button(previewing ? "正在预览…" : "预览替换结果") { makePreview() }.disabled(previewing).accessibilityIdentifier("replace.preview")
                    if !preview.isEmpty { Text(preview).textSelection(.enabled).accessibilityIdentifier("replace.preview.result") }
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }.navigationTitle("编辑净化规则").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { do { try ReadingToolsStore.shared.save(rule); dismiss() } catch { failure = error.localizedDescription } }.accessibilityIdentifier("replace.save")
                    }
                }.onDisappear { previewTask?.cancel() }
        }
    }
    private func makePreview() {
        previewTask?.cancel(); previewing = true; failure = nil
        let current = rule, text = sample, title = previewTitle, book = previewBook
        previewTask = Task {
            defer { previewing = false }
            do {
                let worker = Task.detached { try TransformedReadingText.applying([current], to: text, book: book, origin: "", title: title) }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); preview = value.text; failure = value.warnings.isEmpty ? nil : value.warnings.joined(separator: "\n")
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct ReplacementImportView: View {
    let initialData: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var parsed: ReplacementImport?
    @State private var selection: Set<Int64> = []
    @State private var busy = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                Section("JSON 内容或 HTTP/HTTPS 网址") {
                    TextEditor(text: $input).font(.system(.caption, design: .monospaced)).frame(minHeight: 130)
                    Button(busy ? "正在获取…" : "解析规则") { parse(nil) }.disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let parsed {
                    Section("可导入 \(parsed.rules.count) 条") {
                        ForEach(parsed.rules) { rule in Toggle(rule.name, isOn: Binding(get: { selection.contains(rule.id) }, set: { if $0 { selection.insert(rule.id) } else { selection.remove(rule.id) } })) }
                    }
                    if !parsed.failures.isEmpty { Section("未导入 \(parsed.failures.count) 条") { ForEach(Array(parsed.failures.prefix(30).enumerated()), id: \.offset) { _, error in Text(error).font(.caption).foregroundStyle(.red) } } }
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }.navigationTitle("导入替换规则").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button("确认导入 \(selection.count) 条规则") {
                        do { try ReadingToolsStore.shared.importRules(parsed?.rules.filter { selection.contains($0.id) } ?? []); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(selection.isEmpty || busy).frame(maxWidth: .infinity).padding().background(.bar)
                }.onAppear { if let initialData { parse(initialData) } }.onDisappear { task?.cancel() }
        }
    }
    private func parse(_ data: Data?) {
        task?.cancel(); busy = true; failure = nil; parsed = nil; selection = []
        let text = input
        task = Task {
            defer { busy = false }
            do {
                let worker = Task.detached { if let data { return try ReplacementImport.parse(data) }; return try await ReplacementImport.load(text) }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); parsed = value; selection = Set(value.rules.map(\.id))
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
