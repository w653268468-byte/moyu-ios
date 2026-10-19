#if DEBUG
import Foundation

@MainActor enum FontImportCheck {
    static func run() async {
        let report = URL.documentsDirectory.appendingPathComponent("font-check.json")
        let temp = URL.documentsDirectory.appendingPathComponent("font-test-" + UUID().uuidString + ".ttf")
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "reader.fontFamily")
        let store = ReaderFontStore.shared
        let before = Set(store.faces.map { $0.file })
        defer {
            try? FileManager.default.removeItem(at: temp)
            for face in store.faces where !before.contains(face.file) { try? store.remove(face) }
            if let old { defaults.set(old, forKey: "reader.fontFamily") } else { defaults.removeObject(forKey: "reader.fontFamily") }
        }
        do {
            let (data, _) = try await SourceClient().fetch(URL(string: "http://127.0.0.1:18765/font-test.ttf")!)
            try data.write(to: temp, options: .atomic)
            try store.add(temp)
            store.reload()
            guard let face = store.faces.first(where: { !before.contains($0.file) }) else { throw SourceError.message("导入字体未列入字体管理") }
            defaults.set("custom:" + face.name, forKey: "reader.fontFamily")
            guard ReadingStyle().uiFont.fontName == face.name else { throw SourceError.message("自定义字体未用于实际阅读字体") }
            let backup = try JSONDecoder().decode(ReaderBackup.self, from: BackupService.create())
            guard backup.files["GavinFonts/" + face.file.lastPathComponent] == data else { throw SourceError.message("完整备份未包含字体文件") }
            try Data(#"{"status":"passed","importReloadAndSelect":true,"includedInBackup":true}"#.utf8).write(to: report, options: .atomic)
        } catch {
            let data = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? data?.write(to: report, options: .atomic)
        }
    }
}
#endif
