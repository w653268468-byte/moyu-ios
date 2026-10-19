import SwiftUI

struct SourceSwitchView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    let novel: OnlineNovel
    let chapterIndex: Int
    let onChanged: (OnlineNovel) -> Void
    @State private var sourceID = ""
    @State private var query = ""
    @State private var results: [OnlineNovel] = []
    @State private var catalog: OnlineNovel?
    @State private var target = 0
    @State private var aligned = false
    @State private var busy = false
    @State private var status = ""
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    private var sources: [BookSource] { online.sources.filter { $0.enabled != false && $0.incompatibility == nil } }
    var body: some View {
        NavigationStack {
            Form {
                Section("当前小说") { Text(novel.title); Text(novel.author).foregroundStyle(.secondary) }
                Section("选择替代书源") {
                    Picker("书源", selection: $sourceID) { ForEach(sources) { Text($0.bookSourceName).tag($0.id) } }.disabled(busy)
                    TextField("搜索书名", text: $query).disabled(busy)
                    Button("搜索这个书源") { search() }.disabled(busy || query.isEmpty || sourceID.isEmpty)
                }
                if busy { Section { ProgressView(status); Button("取消") { cancel() } } }
                if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                if let catalog {
                    Section("确认小说和继续章节") {
                        Text(catalog.title).font(.headline)
                        Text(catalog.author).foregroundStyle(.secondary)
                        if !BookIdentity.matches(novel, catalog, allowMissingAuthor: true) { Text("此结果的书名或作者与当前小说不同，请先核对。").foregroundStyle(.orange).font(.caption) }
                        if !aligned { Text("未可靠匹配当前章节，请手动选择继续位置。").foregroundStyle(.orange).font(.caption) }
                        Picker("继续章节", selection: $target) {
                            ForEach(Array(catalog.chapters.enumerated()), id: \.offset) { index, chapter in Text(chapter.title).tag(index) }
                        }.pickerStyle(.navigationLink).disabled(busy)
                        Button("确认切换到这本小说和章节") { commit(catalog) }.disabled(busy || !catalog.chapters.indices.contains(target))
                    }
                } else {
                    Section("搜索结果") {
                        ForEach(results) { book in
                            Button { load(book) } label: {
                                VStack(alignment: .leading, spacing: 5) { Text(book.title).foregroundStyle(.primary); Text(book.author).font(.caption).foregroundStyle(.secondary) }
                            }.disabled(busy)
                        }
                    }
                }
            }.navigationTitle("手动换源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { cancel(); dismiss() } } }
                .onAppear { query = novel.title; sourceID = sources.first(where: { $0.id != novel.sourceID })?.id ?? sources.first?.id ?? "" }
                .onDisappear { cancel() }
        }
    }
    private func cancel() { task?.cancel(); operationID = UUID(); busy = false }
    private func search() {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        cancel(); busy = true; failure = nil; catalog = nil; results = []; status = "正在搜索…"
        let token = operationID
        task = Task {
            do {
                let found = try await online.client.search(query, source: source)
                try Task.checkCancellation(); guard token == operationID else { return }
                results = found
                if found.isEmpty { failure = "这个书源没有搜索结果。" }
            } catch { if !Task.isCancelled && token == operationID { failure = error.localizedDescription } }
            if token == operationID { busy = false }
        }
    }
    private func load(_ book: OnlineNovel) {
        guard let source = sources.first(where: { $0.id == book.sourceID }) else { return }
        cancel(); busy = true; failure = nil; status = "正在读取替代目录…"
        let token = operationID
        task = Task {
            do {
                let loaded = try await online.client.catalog(book, source: source)
                try Task.checkCancellation(); guard token == operationID else { return }
                let title = novel.chapters.indices.contains(chapterIndex) ? novel.chapters[chapterIndex].title : ""
                let match = ChapterAlignment.find(title, in: loaded.chapters)
                target = match ?? min(max(0, chapterIndex), max(0, loaded.chapters.count - 1))
                aligned = match != nil; catalog = loaded
            } catch { if !Task.isCancelled && token == operationID { failure = error.localizedDescription } }
            if token == operationID { busy = false }
        }
    }
    private func commit(_ selected: OnlineNovel) {
        guard let source = sources.first(where: { $0.id == selected.sourceID }), selected.chapters.indices.contains(target) else { return }
        cancel(); busy = true; failure = nil; status = "正在验证目标章节…"
        let token = operationID, chapter = target
        task = Task {
            do {
                let text = try await online.client.chapter(selected.chapters[chapter], source: source)
                try Task.checkCancellation(); guard token == operationID else { return }
                var updated = selected
                updated.shelfID = novel.id; updated.chapterIndex = chapter; updated.textOffset = 0; updated.scrollFraction = nil; updated.lastReadAt = Date()
                try online.commitReplacement(novel, replacement: SourceSwitchResult(novel: updated, text: text))
                onChanged(updated); dismiss()
            } catch { if !Task.isCancelled && token == operationID { failure = error.localizedDescription } }
            if token == operationID { busy = false }
        }
    }
}
