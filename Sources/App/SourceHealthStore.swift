import SwiftUI

@MainActor final class SourceHealthStore: ObservableObject {
    static let shared = SourceHealthStore()
    @Published private(set) var ledger = SourceHealthLedger()
    @Published var message: String?
    private let writer: DeferredSnapshotWriter
    private var locked = false
    let directory: URL
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) {
        self.directory = directory
        writer = DeferredSnapshotWriter(destination: directory.appendingPathComponent("source-health.json"), backup: directory.appendingPathComponent("source-health.backup.json"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("source-health.json")
            if FileManager.default.fileExists(atPath: path.path) { ledger = try JSONDecoder().decode(SourceHealthLedger.self, from: Data(contentsOf: path)) }
        } catch { locked = true; message = "书源状态记录无法读取，已保留原文件。" }
    }
    func receive(_ source: BookSource, failure: String?, latency: Int? = nil, hasResults: Bool = false, verifiedProbe: Bool = false, fullValidation: Bool = false) {
        guard !locked else { return }
        ledger.receive(source, failure: failure, latency: latency, hasResults: hasResults, verifiedProbe: verifiedProbe, fullValidation: fullValidation)
        let snapshot = ledger
        writer.schedule(encode: { try JSONEncoder().encode(snapshot) }, failure: { [weak self] error in Task { @MainActor in self?.message = error.localizedDescription } })
    }
    func reset(_ ids: Set<String>) {
        guard !locked else { return }
        ledger.reset(ids)
        do { let value = ledger; try writer.writeNow { try JSONEncoder().encode(value) } } catch { message = error.localizedDescription }
    }
    func flush() throws { try writer.flush() }
    func reload() {
        writer.discardPendingAndWait()
        do {
            let path = directory.appendingPathComponent("source-health.json")
            ledger = FileManager.default.fileExists(atPath: path.path) ? try JSONDecoder().decode(SourceHealthLedger.self, from: Data(contentsOf: path)) : SourceHealthLedger()
            locked = false; message = nil
        } catch { locked = true; message = "书源状态记录无法读取，已保留原文件。" }
    }
    func cleanup(_ ids: Set<String>, online: OnlineStore) throws {
        guard !locked else { throw SourceError.message(message ?? "书源状态不可读取。") }
        let sources = online.sources.filter { ids.contains($0.id) && ledger.record(for: $0)?.removable == true }
        guard !sources.isEmpty else { throw SourceError.message("没有经过复核的失效书源；超时或登录限制不会自动列入删除。") }
        let data = try SourceImport.export(sources)
        try data.write(to: directory.appendingPathComponent("removed-sources.json"), options: .atomic)
        let removed = Set(sources.map(\.id)); online.deleteSources(removed)
        guard !online.sources.contains(where: { removed.contains($0.id) }) else { throw SourceError.message("删除保存失败，已保留书源。") }
    }
    func restore(online: OnlineStore) throws {
        let sources = try SourceImport.parse(Data(contentsOf: directory.appendingPathComponent("removed-sources.json"))).sources
        try online.addSources(sources); reset(Set(sources.map(\.id)))
    }
}
