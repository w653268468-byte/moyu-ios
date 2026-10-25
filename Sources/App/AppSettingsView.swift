import SwiftUI
import UniformTypeIdentifiers

struct ReaderBackup: Codable {
    var version: Int
    var createdAt: Date
    var files: [String: Data]
    var preferences: Data
}

enum BackupService {
    static let folders = ["Moyu", "MoyuOnline", "GavinFonts"]
    static let maximumBytes = 200 * 1024 * 1024
    static func create() throws -> Data {
        var files: [String: Data] = [:]
        var total = 0
        for folder in folders {
            let url = URL.documentsDirectory.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard info.isRegularFile == true, ["json", "txt", "epub", "ttf", "otf", "ttc"].contains(file.pathExtension) else { continue }
                total += info.fileSize ?? 0
                guard total <= maximumBytes else { throw SourceError.message("备份超过 200 MB，请先清理章节缓存。") }
                files[folder + "/" + file.lastPathComponent] = try Data(contentsOf: file)
            }
        }
        let preferences = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("reader.") }
        let settings = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        return try JSONEncoder().encode(ReaderBackup(version: 1, createdAt: Date(), files: files, preferences: settings))
    }

    @MainActor static func restore(_ data: Data) throws {
        guard data.count <= maximumBytes * 2 else { throw SourceError.message("备份文件过大。") }
        let backup = try JSONDecoder().decode(ReaderBackup.self, from: data)
        guard backup.version == 1, backup.files.count <= 25000 else { throw SourceError.message("备份版本或文件数量不受支持。") }
        var total = 0
        for (path, content) in backup.files {
            let parts = path.components(separatedBy: "/")
            guard parts.count == 2, folders.contains(parts[0]), !parts[1].isEmpty,
                  parts[1] != ".", parts[1] != "..", !parts[1].contains("\\"),
                  ["json", "txt", "epub", "ttf", "otf", "ttc"].contains((parts[1] as NSString).pathExtension) else { throw SourceError.message("备份中含无效文件路径。") }
            total += content.count
            guard total <= maximumBytes else { throw SourceError.message("备份内容超过 200 MB。") }
        }
        if let manifest = backup.files["Moyu/library.json"] {
            let books = try JSONDecoder().decode([Book].self, from: manifest)
            for book in books {
                if book.originalEPUB == true, backup.files["Moyu/\(book.id.uuidString).epub"] == nil { throw SourceError.message("备份缺少《\(book.title)》EPUB 原书。") }
                guard let file = backup.files["Moyu/\(book.id.uuidString).json"] else { throw SourceError.message("备份缺少《\(book.title)》正文。") }
                let document = try JSONDecoder().decode(BookDocument.self, from: file)
                guard !document.pages.isEmpty, document.pages.allSatisfy({ document.chapters.indices.contains($0.chapter) }) else { throw TextImportError.empty }
            }
        } else { throw SourceError.message("备份缺少本地书架索引。") }
        if let index = backup.files["MoyuOnline/index.json"] {
            struct OnlineIndex: Decodable { var sources: [BookSource]; var novels: [OnlineNovel] }
            _ = try JSONDecoder().decode(OnlineIndex.self, from: index)
        }
        if let data = backup.files["MoyuOnline/replace-rules.json"] {
            let rules = try JSONDecoder().decode([TextReplacementRule].self, from: data)
            guard rules.count <= 5000, Set(rules.map(\.id)).count == rules.count else { throw SourceError.message("备份中的替换规则数量或标识无效。") }
            for rule in rules { try rule.validate() }
        }
        if let data = backup.files["MoyuOnline/network-voices.json"], (try JSONSerialization.jsonObject(with: data) as? [Any])?.isEmpty != true { _ = try NetworkVoiceImport.parse(data) }
        if let data = backup.files["MoyuOnline/shelf-organization.json"] {
            let shelf = try JSONDecoder().decode(ShelfOrganization.self, from: data)
            guard shelf.groups.count <= 100, Set(shelf.groups.map(\.id)).count == shelf.groups.count,
                  shelf.groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 }) else { throw SourceError.message("备份中的书架分组格式无效。") }
        }
        guard let preferences = try PropertyListSerialization.propertyList(from: backup.preferences, format: nil) as? [String: Any],
              preferences.keys.allSatisfy({ $0.hasPrefix("reader.") }),
              preferences.values.allSatisfy({ $0 is String || $0 is NSNumber }) else { throw SourceError.message("阅读设置格式无效。") }
        let ranges: [String: ClosedRange<Double>] = [
            "reader.fontSize": 12...44, "reader.lineSpacing": 0...30,
            "reader.letterSpacing": 0...6, "reader.paragraphSpacing": 0...40,
            "reader.horizontalMargin": 10...55, "reader.verticalMargin": 8...60,
            "reader.brightness": 0.35...1, "reader.speechRate": 0.25...0.65,
            "reader.sleepMinutes": 0...180, "reader.search.concurrency": 1...8, "reader.search.timeout": 5...60
        ]
        for (key, range) in ranges {
            if let value = preferences[key] {
                guard let number = value as? NSNumber, number.doubleValue.isFinite, range.contains(number.doubleValue) else { throw SourceError.message("备份中的阅读设置超出范围：\(key)") }
            }
        }
        let manager = FileManager.default
        let staging = URL.documentsDirectory.appendingPathComponent("MoyuRestore-\(UUID().uuidString)")
        let rollback = staging.appendingPathComponent("rollback")
        try manager.createDirectory(at: rollback, withIntermediateDirectories: true)
        var keepRecoveryFiles = false
        defer { if !keepRecoveryFiles { try? manager.removeItem(at: staging) } }
        for folder in folders { try manager.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for (path, content) in backup.files { try content.write(to: staging.appendingPathComponent(path), options: .atomic) }
        var moved: [String] = []
        var installed: [String] = []
        do {
            for folder in folders {
                let active = URL.documentsDirectory.appendingPathComponent(folder)
                if manager.fileExists(atPath: active.path) { try manager.moveItem(at: active, to: rollback.appendingPathComponent(folder)); moved.append(folder) }
                try manager.moveItem(at: staging.appendingPathComponent(folder), to: active)
                installed.append(folder)
            }
        } catch {
            var rollbackFailed = false
            for folder in installed {
                do { try manager.removeItem(at: URL.documentsDirectory.appendingPathComponent(folder)) }
                catch { rollbackFailed = true }
            }
            for folder in moved {
                do { try manager.moveItem(at: rollback.appendingPathComponent(folder), to: URL.documentsDirectory.appendingPathComponent(folder)) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                keepRecoveryFiles = true
                throw SourceError.message("恢复失败，原文件保留在“文件 → Gavin → \(staging.lastPathComponent) → rollback”，请先备份该文件夹。")
            }
            throw error
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("reader.") { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) }
        ReaderFontStore.shared.reload()
        ReadingToolsStore.shared.reload()
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var online: OnlineStore
    @EnvironmentObject private var library: LibraryStore
    @State private var exporting = false
    @State private var export: JSONExport?
    @State private var importing = false
    @State private var pendingRestore: URL?
    @State private var confirmRestore = false
    @State private var confirmCache = false
    @State private var message: String?
    @AppStorage("reader.interfaceAppearance") private var interfaceAppearance = InterfaceAppearance.light.rawValue
    private func progressSnapshot() throws -> Data {
        try library.flushProgress(); try online.flushProgress()
        return try BackupService.create()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 15) {
                        Image(systemName: "book.pages.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Gavin").font(.title2.bold())
                            Text("让阅读，更合你的心意。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                Section("阅读") {
                    NavigationLink { NetworkVoicesView() } label: { Label("在线音色与朗读", systemImage: "waveform") }
                    Picker("界面外观", selection: $interfaceAppearance) {
                        ForEach(InterfaceAppearance.allCases) { appearance in Text(appearance.name).tag(appearance.rawValue) }
                    }.accessibilityIdentifier("settings.appearance")
                    NavigationLink { ReplacementRulesView() } label: { Label("替换净化", systemImage: "text.badge.minus") }
                    NavigationLink { ReadingPreferences() } label: { Label("字体、排版与主题", systemImage: "textformat.size") }
                    NavigationLink { ReaderFontSettings() } label: { Label("自定义字体", systemImage: "textformat.abc") }
                    NavigationLink { SearchConfigurationView() } label: { Label("搜索设置", systemImage: "magnifyingglass") }
                    LabeledContent("本地书籍", value: "\(library.books.count) 本")
                    LabeledContent("在线书架", value: "\(online.novels.count) 本")
                    LabeledContent("书源", value: "\(online.sources.count) 个")
                }
                Section("备份与恢复") {
                    NavigationLink("WebDAV 跨设备同步") { WebDAVSettingsView() }
                    Button("导出完整备份", systemImage: "square.and.arrow.up") {
                        do { export = JSONExport(data: try progressSnapshot()); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                    Button("从备份恢复", systemImage: "arrow.counterclockwise") { importing = true }
                    Text("包含书籍、书源、进度、书签备注、章节缓存、自定义字体及阅读设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("存储") {
                    Button("清理在线章节缓存", role: .destructive) { confirmCache = true }
                    Text("清理后未连接网站时将无法读取这些章节；本地书籍和书架记录保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("帮助与关于") {
                    NavigationLink("支持格式、兼容性与关于") { AppAboutView() }
                    Text(AppBuildIdentity.label).font(.caption).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(InterfaceAppearance.background).navigationTitle("设置")
                .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "Gavin完整备份.json") { result in
                    if case .failure(let error) = result { message = error.localizedDescription }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do { pendingRestore = try result.get(); confirmRestore = true } catch { message = error.localizedDescription }
                }
                .confirmationDialog("用备份替换当前书架和设置？", isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button("恢复备份", role: .destructive) { restore() }
                } message: { Text("建议先导出当前备份。仅支持Gavin导出的完整备份文件。") }
                .confirmationDialog("清理全部在线章节缓存？", isPresented: $confirmCache, titleVisibility: .visible) {
                    Button("清理缓存", role: .destructive) { Task { await online.clearCache() } }
                }
                .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("知道了") { message = nil }
                } message: { Text(message ?? "") }
        }
    }
    private func restore() {
        guard let url = pendingRestore else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; pendingRestore = nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= BackupService.maximumBytes * 2 else { throw SourceError.message("备份文件过大。") }
            try library.flushProgress(); try online.flushProgress()
            try BackupService.restore(Data(contentsOf: url))
            library.reload(); online.reload(); NetworkVoiceStore.shared.reload(); message = "备份已恢复。"
        } catch { message = error.localizedDescription }
    }
}

struct AppAboutView: View {
    var body: some View {
        Form {
                Section("导入格式") {
                    Text("TXT · EPUB · PDF · Markdown · HTML · RTF · DOCX · MOBI · AZW3")
                    Text("EPUB 保留原文件、图片和 CSS，可切换原书样式与重排。旧版已导入的 EPUB 需重新导入原文件。DOCX 与富文本以文字重排；扫描 PDF 尝试本机 OCR；未加密 MOBI/AZW3 转为保留图片与目录的 EPUB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("兼容性") {
                    Text("CSS、旧式选择器、XPath 1.0、基础 JSONPath、静态 GET/POST、目录及正文分页。")
                    Text("支持常用脚本接口、发现分类、换源与仿真卷页；完整 Java/Android 桥仍待补齐，当前版本不等同 Android Legado 完整版。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Gavin 2.0") {
                    Text(AppBuildIdentity.label).font(.caption).textSelection(.enabled)
                    Link("项目源码与安装包", destination: URL(string: "https://github.com/w653268468-byte/moyu-ios")!)
                    Text("主程序 MIT · libmobi LGPL-3.0-or-later · 无广告")
                    Link("第三方许可与重新编译说明", destination: URL(string: "https://github.com/w653268468-byte/moyu-ios/blob/main/THIRD_PARTY_NOTICES.md")!)
                    Text("免费 Apple 账号签名通常需每 7 天续签。用 Sideloadly 覆盖安装同一包名；不要先删 App，以免丢失本地数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("帮助与关于").navigationBarTitleDisplayMode(.inline)
    }
}
