import SwiftUI
import CoreText
import CryptoKit
import UniformTypeIdentifiers

struct ReaderFontFace: Identifiable { var id: String { name }; let name: String; let title: String; let file: URL }

final class ReaderFontStore: ObservableObject {
    static let shared = ReaderFontStore()
    @Published private(set) var faces: [ReaderFontFace] = []
    @Published var message: String?
    let directory = URL.documentsDirectory.appendingPathComponent("GavinFonts", isDirectory: true)
    init() { reload() }
    func reload() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var found: [ReaderFontFace] = []
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 40 * 1024 * 1024 else { continue }
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                for descriptor in descriptors.prefix(32) {
                    let font = CTFontCreateWithFontDescriptor(descriptor, 20, nil)
                    let name = CTFontCopyPostScriptName(font) as String
                    guard !found.contains(where: { $0.name == name }) else { continue }
                    found.append(ReaderFontFace(name: name, title: CTFontCopyFullName(font) as String, file: url))
                }
            }
            faces = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { message = "字体读取失败：" + error.localizedDescription }
    }
    func add(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(ext) else { throw SourceError.message("请选择 TTF、OTF 或 TTC 字体。") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 40 * 1024 * 1024 else { throw SourceError.message("单个字体需在 40 MB 以内。") }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty, descriptors.count <= 32 else { throw SourceError.message("无法读取字体，或字体集合超过 32 个字形系列。") }
        let importedNames = descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 20, nil)) as String }
        if importedNames.allSatisfy({ name in faces.contains(where: { $0.name == name }) }) {
            message = "同名字体已导入，可直接选择；如需替换，请先删除旧字体文件。"
            return
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(hash + "." + ext)
        if !FileManager.default.fileExists(atPath: target.path) {
            guard files.count < 30 else { throw SourceError.message("最多保存 30 个字体文件，请先删除不需要的字体。") }
            try data.write(to: target, options: .atomic)
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(target as CFURL, .process, &error) {
            _ = error?.takeRetainedValue()
            let names = descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 20, nil)) as String }
            if !names.allSatisfy({ UIFont(name: $0, size: 20) != nil }) {
                try? FileManager.default.removeItem(at: target)
                throw SourceError.message("字体注册失败，请尝试另一份字体文件。")
            }
        }
        reload()
    }
    func remove(_ face: ReaderFontFace) throws {
        let family = UserDefaults.standard.string(forKey: "reader.fontFamily") ?? ""
        if faces.contains(where: { $0.file == face.file && family == "custom:" + $0.name }) { UserDefaults.standard.set("系统", forKey: "reader.fontFamily") }
        CTFontManagerUnregisterFontsForURL(face.file as CFURL, .process, nil)
        try FileManager.default.removeItem(at: face.file)
        reload()
    }
}

struct ReaderFontSettings: View {
    @ObservedObject private var store = ReaderFontStore.shared
    @AppStorage("reader.fontFamily") private var selected = "宋体"
    @State private var importing = false
    var body: some View {
        List {
            Section {
                Button("从文件导入字体", systemImage: "square.and.arrow.down") { importing = true }
                Text("支持 TTF、OTF、TTC，单个文件最多 40 MB。导入后用于文字分页、滚动和排版预览；EPUB 原书样式保留书内字体。").font(.caption).foregroundStyle(.secondary)
            }
            Section("已导入 · \(store.faces.count) 款字体") {
                if store.faces.isEmpty { Text("尚未导入字体").foregroundStyle(.secondary) }
                ForEach(store.faces) { face in
                    Button { selected = "custom:" + face.name } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(face.title).foregroundStyle(.primary); Spacer(); if selected == "custom:" + face.name { Image(systemName: "checkmark") } }
                            Text("风吹过书页，故事从这里开始。").font(.custom(face.name, size: 20)).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除字体文件", role: .destructive) { do { try store.remove(face) } catch { store.message = error.localizedDescription } } }
                }
            }
        }.navigationTitle("自定义字体").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttc")].compactMap { $0 }) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try store.add(url) }
                catch { store.message = error.localizedDescription }
            }
            .alert("字体提示", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("知道了") { store.message = nil } } message: { Text(store.message ?? "") }
    }
}
