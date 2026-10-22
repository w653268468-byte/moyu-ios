import SwiftUI

@MainActor final class ReadingToolsStore: ObservableObject {
    static let shared = ReadingToolsStore()
    @Published private(set) var rules: [TextReplacementRule] = []
    @Published private(set) var revision = UUID()
    @Published private(set) var message: String?
    private var locked = false
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("replace-rules.json") }
    private var backup: URL { directory.appendingPathComponent("replace-rules.backup.json") }
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) { self.directory = directory; reload() }
    func reload() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                do { rules = try JSONDecoder().decode([TextReplacementRule].self, from: Data(contentsOf: file)) }
                catch { rules = try JSONDecoder().decode([TextReplacementRule].self, from: Data(contentsOf: backup)); message = "替换规则已从备份恢复。" }
            } else { rules = [] }
            locked = false; revision = UUID()
        } catch { locked = true; message = "读取净化规则失败，已保留原文件并暂停写入。" }
    }
    func commit(_ values: [TextReplacementRule]) throws {
        guard !locked else { throw SourceError.message("净化规则暂时无法写入，请先重新读取。") }
        guard values.count <= 5000 else { throw SourceError.message("最多保存 5000 条净化规则。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(rules).write(to: backup, options: .atomic)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        rules = values; revision = UUID(); message = nil
        if ReaderSpeech.shared.active { ReaderSpeech.shared.stop(); ReaderSpeech.shared.message = "净化规则已更新，重新开始听书即可应用。" }
    }
    func save(_ rule: TextReplacementRule) throws {
        try rule.validate()
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { var new = rule; new.order = (next.map(\.order).max() ?? -1) + 1; next.append(new) }
        try commit(next)
    }
    func importRules(_ imported: [TextReplacementRule]) throws {
        var next = rules
        for rule in imported {
            try rule.validate()
            if let index = next.firstIndex(where: { $0.id == rule.id || ($0.name == rule.name && $0.pattern == rule.pattern && $0.group == rule.group) }) { next[index] = rule }
            else { next.append(rule) }
        }
        next = next.enumerated().sorted { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }.map(\.element)
        try commit(next)
    }
    func setEnabled(_ rule: TextReplacementRule, _ enabled: Bool) {
        do { var changed = rule; changed.isEnabled = enabled; try save(changed) }
        catch { message = error.localizedDescription }
    }
}

@MainActor final class SpeechTextPresentation {
    private var maps: [Int: TransformedReadingText] = [:]
    private let rules: [TextReplacementRule]
    private let conversion: String
    init(rules: [TextReplacementRule], conversion: String) { self.rules = rules; self.conversion = conversion }
    convenience init() { self.init(rules: ReadingToolsStore.shared.rules, conversion: UserDefaults.standard.string(forKey: "reader.characterConversion") ?? "none") }
    func prepare(index: Int, title: String, text: String, book: String, origin: String) async throws -> (String, String) {
        let active = rules, mode = conversion
        let worker = Task.detached {
            let body = try TransformedReadingText.applying(active, to: TextPagination.readingText(text), book: book, origin: origin, conversion: mode).normalizedLines()
            let heading = try TransformedReadingText.applying(active, to: title, book: book, origin: origin, title: true, conversion: mode)
            return (body, heading.text)
        }
        let (body, heading) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        // Retain only the current chapter map; continuous listening does not need earlier chapters.
        maps = [index: body]
        return (heading, body.text)
    }
    func offset(chapter: Int, value: Int, original: Bool) -> Int {
        guard let map = maps[chapter] else { return value }
        return original ? map.originalOffset(value) : map.displayOffset(value)
    }
}

struct ReadingTextSnapshot: Sendable {
    let body: TransformedReadingText
    let title: String
    let warnings: [String]
}

private struct ReadingTextKey: Equatable {
    let text: String
    let title: String
    let revision: UUID
    let conversion: String
}

struct ReadingTextPresentation<Content: View>: View {
    @ObservedObject private var tools = ReadingToolsStore.shared
    @AppStorage("reader.characterConversion") private var conversion = "none"
    let text: String
    let title: String
    let book: String
    let origin: String
    @ViewBuilder var content: (ReadingTextSnapshot) -> Content
    @State private var snapshot: ReadingTextSnapshot?
    @State private var finishedKey: ReadingTextKey?
    @State private var renderID = UUID()
    @State private var bypass = false
    @State private var showRules = false
    private var key: ReadingTextKey { ReadingTextKey(text: text, title: title, revision: tools.revision, conversion: conversion) }
    private var enabled: [TextReplacementRule] { tools.rules.filter { $0.isEnabled } }
    var body: some View {
        Group {
            if bypass || (enabled.isEmpty && conversion == "none") {
                content(ReadingTextSnapshot(body: TransformedReadingText(text), title: title, warnings: []))
            } else if finishedKey == key, let snapshot {
                if snapshot.body.text.isEmpty && !text.isEmpty {
                    ContentUnavailableView { Label("净化后正文为空", systemImage: "text.badge.minus") }
                    description: { Text("可以查看原文或调整替换规则。") }
                    actions: { Button("本章查看原文") { bypass = true }; Button("调整净化规则") { showRules = true } }
                } else {
                    VStack(spacing: 0) {
                        if !snapshot.warnings.isEmpty {
                            Button("已跳过 \(snapshot.warnings.count) 条净化处理 · 查看规则") { showRules = true }.font(.caption).padding(8)
                        }
                        content(snapshot).id(renderID)
                    }
                }
            } else { ProgressView("正在整理正文…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: key) {
            bypass = false
            let current = key, rules = enabled, original = text, heading = title, bookName = book, source = origin, mode = conversion
            guard !rules.isEmpty || mode != "none" else { return }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let body = try TransformedReadingText.applying(rules, to: TextPagination.readingText(original), book: bookName, origin: source, conversion: mode).normalizedLines()
                    let title = try TransformedReadingText.applying(rules, to: heading, book: bookName, origin: source, title: true, conversion: mode)
                    return ReadingTextSnapshot(body: body, title: title.text, warnings: body.warnings + title.warnings)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                snapshot = result; finishedKey = current; renderID = UUID()
            } catch { if !Task.isCancelled { snapshot = ReadingTextSnapshot(body: TransformedReadingText(TextPagination.readingText(original)), title: heading, warnings: [error.localizedDescription]); finishedKey = current; renderID = UUID() } }
        }
        .sheet(isPresented: $showRules) { NavigationStack { ReplacementRulesView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showRules = false } } } } }
    }
}
