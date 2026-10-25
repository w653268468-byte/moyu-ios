import SwiftUI

@MainActor final class NetworkVoiceStore: ObservableObject {
    static let shared = NetworkVoiceStore()
    @Published private(set) var engines: [NetworkSpeechEngine] = []
    @Published var message: String?
    private let writer: DeferredSnapshotWriter
    private var locked = false
    private let file: URL
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) {
        file = directory.appendingPathComponent("network-voices.json")
        writer = DeferredSnapshotWriter(destination: directory.appendingPathComponent("network-voices.json"), backup: directory.appendingPathComponent("network-voices.backup.json"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                if (try? JSONSerialization.jsonObject(with: data) as? [Any])?.isEmpty != true { engines = try NetworkVoiceImport.parse(data).engines }
            }
        } catch { locked = true; message = "网络音色配置无法读取，已保留原文件。" }
    }
    func add(_ values: [NetworkSpeechEngine]) throws {
        guard !locked else { throw SourceError.message(message ?? "音色配置暂不可写入。") }
        let old = engines
        for engine in values {
            if let index = engines.firstIndex(where: { $0.id == engine.id }) { engines[index] = engine } else { engines.append(engine) }
        }
        guard engines.count <= 500 else { engines = old; throw SourceError.message("最多保存 500 个音色配置。") }
        do { let snapshot = engines; try writer.writeNow { try NetworkVoiceImport.export(snapshot) } } catch { engines = old; throw error }
    }
    func remove(_ id: Int64) throws {
        guard !locked else { throw SourceError.message("音色配置暂不可写入。") }
        let old = engines; engines.removeAll { $0.id == id }
        do {
            let snapshot = engines
            // The empty collection is valid for storage even though import requires a usable item.
            try writer.writeNow { try NetworkVoiceImport.export(snapshot) }
            if UserDefaults.standard.string(forKey: "reader.speechEngine") == String(id) { ReaderSpeech.shared.changeVoice(nil) }
        } catch { engines = old; throw error }
    }
    func select(_ engine: NetworkSpeechEngine?) { ReaderSpeech.shared.changeVoice(engine) }
    func reload() {
        // Re-read after a complete backup restore.
        do {
            if !FileManager.default.fileExists(atPath: file.path) { engines = []; locked = false; return }
            let data = try Data(contentsOf: file)
            if (try? JSONSerialization.jsonObject(with: data) as? [Any])?.isEmpty == true { engines = [] }
            else { engines = try NetworkVoiceImport.parse(data).engines }
            locked = false
        } catch { locked = true; message = error.localizedDescription }
    }
}
