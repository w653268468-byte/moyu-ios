import SwiftUI
import UniformTypeIdentifiers

struct NetworkVoicesView: View {
    @ObservedObject private var store = NetworkVoiceStore.shared
    @ObservedObject private var player = ReaderSpeech.shared
    @AppStorage("reader.speechEngine") private var selected = ""
    @AppStorage("reader.networkSpeechSpeed") private var speed = 10
    @State private var importing = false
    @State private var editing: NetworkSpeechEngine?
    @State private var configuring: NetworkSpeechEngine?
    @State private var export: JSONExport?
    @State private var exporting = false
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                Button { store.select(nil) } label: { HStack { Label("系统离线朗读", systemImage: "iphone"); Spacer(); if selected.isEmpty { Image(systemName: "checkmark") } } }
                Button("链接 / JSON / 文件导入音色", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("voices.import")
                Stepper("网络语速 · \(speed)", value: $speed, in: 5...50)
                Text("选择音色后可试听，听书时也可切换；网络语速从下一段生效。网络朗读会把当前段落发送给配置中的服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = store.message { Text(message).foregroundStyle(.orange) }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if let message = player.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if store.engines.isEmpty { ContentUnavailableView("导入喜欢的网络音色", systemImage: "waveform", description: Text("支持安卓阅读在线朗读 JSON 配置、网址与文件导入。")) }
            ForEach(store.engines) { engine in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(engine.name).font(.headline); Spacer(); if selected == String(engine.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) } }
                    HStack(spacing: 22) {
                        Button("使用") { store.select(engine) }.accessibilityIdentifier("voice.use.\(engine.id)").accessibilityValue(selected == String(engine.id) ? "已选择" : "未选择")
                        Button("试听") { player.preview(engine) }.accessibilityIdentifier("voice.preview.\(engine.id)")
                        Button("音色与登录参数") { configuring = engine }
                    }.buttonStyle(.borderless).font(.subheadline)
                    Text(engine.contentType ?? "导入后请先试听确认接口可用").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6).swipeActions {
                    Button("删除", role: .destructive) { do { try store.remove(engine.id) } catch { failure = error.localizedDescription } }
                    Button("编辑") { editing = engine }.tint(.blue)
                }.contextMenu { Button("编辑配置") { editing = engine } }
            }
        }.scrollContentBackground(.hidden).background(InterfaceAppearance.background)
            .navigationTitle("在线音色与朗读").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { importing = true } label: { Image(systemName: "plus") }; Button("导出") { do { export = JSONExport(data: try NetworkVoiceImport.export(store.engines)); exporting = true } catch { failure = error.localizedDescription } }.disabled(store.engines.isEmpty) }
            .sheet(isPresented: $importing) { NetworkVoiceImportView() }
            .sheet(item: $editing) { engine in NetworkVoiceEditView(engine: engine) }
            .sheet(item: $configuring) { engine in NetworkVoiceParametersView(engine: engine) }
            .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "Gavin网络音色.json") { if case .failure(let error) = $0 { failure = error.localizedDescription } }
    }
}

private struct NetworkVoiceImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: NetworkVoiceImport?
    @State private var failure: String?
    @State private var busy = false
    @State private var file = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴音色网址或 JSON") {
                    TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 160).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("voices.input")
                    Button("读取剪贴板") { text = UIPasteboard.general.string ?? "" }
                    Button("选择配置文件") { file = true }
                    Button("获取并预览") { parse() }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("voices.parse")
                }
                if busy { ProgressView("正在获取音色配置…"); Button("取消") { task?.cancel(); busy = false } }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if let result {
                    Section("预览 · \(result.engines.count) 个音色") { ForEach(result.engines) { engine in Text(engine.name) }; ForEach(result.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } }
                }
                Text("支持阅读 HttpTTS 格式与 HTTP/HTTPS 音频接口。导入保存不代表服务可用，请先试听；需 Android 或 WebSocket 的特殊引擎可能不兼容。")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("导入网络音色").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    if let result { Button("导入 \(result.engines.count) 个音色") { do { try NetworkVoiceStore.shared.add(result.engines); dismiss() } catch { failure = error.localizedDescription } }.buttonStyle(.borderedProminent).padding().frame(maxWidth: .infinity).background(.bar).accessibilityIdentifier("voices.confirm") }
                }
                .fileImporter(isPresented: $file, allowedContentTypes: [.data]) { value in
                    do {
                        let url = try value.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5 * 1024 * 1024 else { throw SourceError.message("音色文件超过 5 MB。") }
                        text = String(decoding: try Data(contentsOf: url), as: UTF8.self); parse()
                    } catch { failure = error.localizedDescription }
                }.onDisappear { task?.cancel() }
        }
    }
    private func parse() {
        task?.cancel(); busy = true; failure = nil; result = nil
        let input = text
        task = Task {
            defer { busy = false }
            do { let value = try await NetworkSpeechClient().importText(input); try Task.checkCancellation(); result = value }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct NetworkVoiceEditView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: NetworkSpeechEngine
    @State private var text = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack { Form {
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 400).autocorrectionDisabled().textInputAutocapitalization(.never)
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("编辑音色配置").toolbar {
            Button("取消") { dismiss() }
            Button("保存") { do { let result = try NetworkVoiceImport.parse(Data(text.utf8)); guard result.engines.count == 1, result.engines[0].id == engine.id else { throw SourceError.message("编辑时请保留原音色 id。") }; ReaderSpeech.shared.stop(); try NetworkVoiceStore.shared.add(result.engines); dismiss() } catch { failure = error.localizedDescription } }
        }.onAppear { text = String(decoding: (try? NetworkVoiceImport.export([engine])) ?? Data(), as: UTF8.self) } }
    }
}

private struct VoiceLoginField: Identifiable {
    let name: String
    let choices: [String]
    var id: String { name }
}
private struct NetworkVoiceParametersView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: NetworkSpeechEngine
    private let client = NetworkSpeechClient()
    @State private var fields: [VoiceLoginField] = []
    @State private var values: [String: String] = [:]
    @State private var raw = "{}"
    @State private var advanced = false
    @State private var failure: String?
    var body: some View {
        NavigationStack { Form {
            ForEach(fields) { field in
                if field.choices.isEmpty { TextField(field.name, text: Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0 })).textInputAutocapitalization(.never).autocorrectionDisabled() }
                else { Picker(field.name, selection: Binding(get: { values[field.name] ?? field.choices.first ?? "" }, set: { values[field.name] = $0 })) { ForEach(field.choices, id: \.self) { Text($0).tag($0) } } }
            }
            Toggle("编辑完整登录参数 JSON", isOn: $advanced)
            if advanced || fields.isEmpty { TextEditor(text: $raw).font(.system(.caption, design: .monospaced)).frame(minHeight: 160).autocorrectionDisabled().textInputAutocapitalization(.never) }
            Text("按音色服务要求填写参数；登录参数存入本机钥匙串，不随普通备份导出。")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
        }.navigationTitle("音色与登录参数").navigationBarTitleDisplayMode(.inline).toolbar {
            Button("取消") { dismiss() }
            Button("保存") { Task {
                do {
                    let json: String
                    if advanced || fields.isEmpty { json = raw }
                    else {
                        var object = (try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                        for field in fields { object[field.name] = values[field.name] ?? field.choices.first ?? "" }
                        json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    }
                    try await client.setLoginInfo(json, engine: engine); ReaderSpeech.shared.stop(); dismiss()
                } catch { failure = error.localizedDescription }
            } }
        }.task {
            do {
                raw = try await client.loginInfo(engine)
                let object = (try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                values = object.reduce(into: [:]) { result, item in result[item.key] = String(describing: item.value) }
                let ui = try await client.fields(engine)
                if let rows = try JSONSerialization.jsonObject(with: Data(ui.utf8)) as? [[String: Any]] {
                    fields = rows.compactMap { row in guard let name = row["name"] as? String else { return nil }; return VoiceLoginField(name: name, choices: (row["chars"] as? [String]) ?? []) }
                }
            } catch { failure = error.localizedDescription }
        } }
    }
}
