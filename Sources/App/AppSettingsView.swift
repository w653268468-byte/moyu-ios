import SwiftUI
import UniformTypeIdentifiers

private struct ReaderBackup: Codable {
    var version: Int
    var createdAt: Date
    var files: [String: Data]
    var preferences: Data
}

private enum BackupService {
    static let folders = ["Moyu", "MoyuOnline"]
    static let maximumBytes = 200 * 1024 * 1024
    static func create() throws -> Data {
        var files: [String: Data] = [:]
        var total = 0
        for folder in folders {
            let url = URL.documentsDirectory.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard info.isRegularFile == true, ["json", "txt"].contains(file.pathExtension) else { continue }
                total += info.fileSize ?? 0
                guard total <= maximumBytes else { throw SourceError.message("备份超过 200 MB，请先清理章节缓存。") }
                files[folder + "/" + file.lastPathComponent] = try Data(contentsOf: file)
            }
        }
        let preferences = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("reader.") }
        let settings = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        return try JSONEncoder().encode(ReaderBackup(version: 1, createdAt: Date(), files: files, preferences: settings))
    }

    static func restore(_ data: Data) throws {
        guard data.count <= maximumBytes * 2 else { throw SourceError.message("备份文件过大。") }
        let backup = try JSONDecoder().decode(ReaderBackup.self, from: data)
        guard backup.version == 1, backup.files.count <= 25000 else { throw SourceError.message("备份版本或文件数量不受支持。") }
        var total = 0
        for (path, content) in backup.files {
            let parts = path.components(separatedBy: "/")
            guard parts.count == 2, folders.contains(parts[0]), !parts[1].isEmpty,
                  parts[1] != ".", parts[1] != "..", !parts[1].contains("\\"),
                  ["json", "txt"].contains((parts[1] as NSString).pathExtension) else { throw SourceError.message("备份中含无效文件路径。") }
            total += content.count
            guard total <= maximumBytes else { throw SourceError.message("备份内容超过 200 MB。") }
        }
        if let manifest = backup.files["Moyu/library.json"] {
            let books = try JSONDecoder().decode([Book].self, from: manifest)
            for book in books {
                guard let file = backup.files["Moyu/\(book.id.uuidString).json"] else { throw SourceError.message("备份缺少《\(book.title)》正文。") }
                let document = try JSONDecoder().decode(BookDocument.self, from: file)
                guard !document.pages.isEmpty, document.pages.allSatisfy({ document.chapters.indices.contains($0.chapter) }) else { throw TextImportError.empty }
            }
        } else { throw SourceError.message("备份缺少本地书架索引。") }
        if let index = backup.files["MoyuOnline/index.json"] {
            struct OnlineIndex: Decodable { var sources: [BookSource]; var novels: [OnlineNovel] }
            _ = try JSONDecoder().decode(OnlineIndex.self, from: index)
        }
        guard let preferences = try PropertyListSerialization.propertyList(from: backup.preferences, format: nil) as? [String: Any],
              preferences.keys.allSatisfy({ $0.hasPrefix("reader.") }),
              preferences.values.allSatisfy({ $0 is String || $0 is NSNumber }) else { throw SourceError.message("阅读设置格式无效。") }
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
                throw SourceError.message("恢复失败，原文件保留在“文件 → 墨屿 → \(staging.lastPathComponent) → rollback”，请先备份该文件夹。")
            }
            throw error
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("reader.") { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) }
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
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    NavigationLink("字体、排版与主题") { ReadingPreferences() }
                    LabeledContent("本地书籍", value: "\(library.books.count) 本")
                    LabeledContent("在线书架", value: "\(online.novels.count) 本")
                    LabeledContent("书源", value: "\(online.sources.count) 个")
                }
                Section("备份与恢复") {
                    Button("导出完整备份", systemImage: "square.and.arrow.up") {
                        do { export = JSONExport(data: try BackupService.create()); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                    Button("从备份恢复", systemImage: "arrow.counterclockwise") { importing = true }
                    Text("包含本地文字书、书架、进度、书签、书源、章节缓存及阅读设置。备份可能包含你的私人阅读内容，请保存在自己的位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("存储") {
                    Button("清理在线章节缓存", role: .destructive) { confirmCache = true }
                    Text("清理后未连接网站时将无法读取这些章节；本地书籍和书架记录保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("导入格式") {
                    Text("TXT · EPUB · PDF · Markdown · HTML · RTF · DOCX")
                    Text("EPUB、DOCX 与富文本以纯文字重排；PDF 按页提取文字。暂无 OCR、DRM 解锁、MOBI/AZW3。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("兼容性") {
                    Text("CSS、旧式选择器、基础 JSONPath、静态 GET/POST、目录及正文分页。")
                    Text("复杂 JavaScript/Java 桥、XPath、WebView 验证、发现页、仿真翻页与 WebDAV 同步仍待实现；当前版本不等同 Android Legado 完整版。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("墨屿 2.0") {
                    Link("项目源码与安装包", destination: URL(string: "https://github.com/w653268468-byte/moyu-ios")!)
                    Text("MIT 开源许可 · 无广告 · 书籍保存在本机")
                    Text("免费 Apple 账号签名通常需每 7 天续签。用 Sideloadly 覆盖安装同一包名；不要先删 App，以免丢失本地数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("设置")
                .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "墨屿完整备份.json") { result in
                    if case .failure(let error) = result { message = error.localizedDescription }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do { pendingRestore = try result.get(); confirmRestore = true } catch { message = error.localizedDescription }
                }
                .confirmationDialog("用备份替换当前书架和设置？", isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button("恢复备份", role: .destructive) { restore() }
                } message: { Text("建议先导出当前备份。仅支持墨屿导出的完整备份文件。") }
                .confirmationDialog("清理全部在线章节缓存？", isPresented: $confirmCache, titleVisibility: .visible) {
                    Button("清理缓存", role: .destructive) { online.clearCache() }
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
            try BackupService.restore(Data(contentsOf: url))
            library.reload(); online.reload(); message = "备份已恢复。"
        } catch { message = error.localizedDescription }
    }
}
