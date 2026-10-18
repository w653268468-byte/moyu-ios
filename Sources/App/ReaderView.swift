import SwiftUI

struct ReaderLoader: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var document: BookDocument?
    @State private var failure: String?

    var body: some View {
        Group {
            if let document {
                ReaderView(book: book, document: document)
            } else if let failure {
                ContentUnavailableView("无法打开小说", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回") { dismiss() } } }
            } else { ProgressView("正在打开…") }
        }.task {
            do { document = try await library.document(for: book) }
            catch { failure = error.localizedDescription }
        }
    }
}

private enum ReaderPanel: String, Identifiable {
    case contents, search, settings
    var id: String { rawValue }
}

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let document: BookDocument
    @State private var page = 0
    @State private var panel: ReaderPanel?
    @State private var search = ""
    @StateObject private var speech = ReaderSpeech()
    private var style = ReadingStyle()
    private var liveBook: Book { library.books.first { $0.id == book.id } ?? book }
    private var current: ReadingPage { document.pages[page] }
    private var marked: Bool { liveBook.bookmarks.contains { $0.page == page } }

    init(book: Book, document: BookDocument) {
        self.book = book
        self.document = document
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if style.showChapterTitle {
                        Text(document.chapters[current.chapter].title).font(.caption).opacity(0.6)
                    }
                    ReadingParagraphs(text: current.text)
                }.padding(.horizontal, style.horizontalMargin).padding(.vertical, style.verticalMargin).frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }.id(page)
            HStack {
                Button { jump(page - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(page == 0).accessibilityLabel("上一页")
                Spacer()
                Text("\(page + 1) / \(document.pages.count)").font(.caption).monospacedDigit()
                Spacer()
                Button { jump(page + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(page == document.pages.count - 1).accessibilityLabel("下一页")
            }.padding(.horizontal, 16)
        }
        .background(style.paper.background).foregroundStyle(style.paper.ink)
        .preferredColorScheme(style.paper.isDark ? .dark : .light)
        .modifier(ReadingAppearance())
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("返回书架")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleBookmark(bookID: book.id, page: current) } label: {
                    Image(systemName: marked ? "bookmark.fill" : "bookmark")
                }.accessibilityLabel(marked ? "移除书签" : "添加书签")
                Menu {
                    Button(speech.active ? (speech.paused ? "继续朗读" : "暂停朗读") : "朗读当前分段", systemImage: "speaker.wave.2") { speech.play(current.text, rate: style.speechRate) }
                    if speech.active { Button("停止朗读", systemImage: "stop.circle") { speech.stop() } }
                    Button("目录与书签", systemImage: "list.bullet") { panel = .contents }
                    Button("搜索正文", systemImage: "magnifyingglass") { panel = .search }
                    Button("阅读设置", systemImage: "textformat.size") { panel = .settings }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("阅读菜单")
            }
        }
        .onAppear {
            page = min(max(0, liveBook.page), document.pages.count - 1)
            library.updatePosition(bookID: book.id, page: page)
        }
        .onChange(of: page) { _, value in speech.stop(); library.updatePosition(bookID: book.id, page: value) }
        .onDisappear { speech.stop() }
        .alert("听书提示", isPresented: Binding(get: { speech.message != nil }, set: { if !$0 { speech.message = nil } })) { Button("知道了") { speech.message = nil } } message: { Text(speech.message ?? "") }
        .sheet(item: $panel) { selected in
            NavigationStack {
                Group {
                    switch selected {
                    case .settings: ReadingPreferences()
                    case .contents: contents
                    case .search: searchResults
                    }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { panel = nil } } }
            }
        }
    }

    private func jump(_ target: Int) { page = min(max(0, target), document.pages.count - 1) }

    private var contents: some View {
        List {
            Section("目录 · \(document.chapters.count) 章") {
                ForEach(document.chapters) { chapter in
                    Button { jump(chapter.firstPage); panel = nil } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if chapter.id == current.chapter { Image(systemName: "speaker.wave.1") }
                        }
                    }
                }
            }
            Section("书签 · \(liveBook.bookmarks.count)") {
                if liveBook.bookmarks.isEmpty { Text("点击阅读页右上角的书签保存位置。").foregroundStyle(.secondary) }
                ForEach(liveBook.bookmarks) { mark in
                    Button { jump(mark.page); panel = nil } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(mark.page + 1) 页").font(.caption).foregroundStyle(.secondary)
                            Text(mark.excerpt).lineLimit(2).foregroundStyle(.primary)
                        }
                    }.swipeActions {
                        Button("移除", role: .destructive) {
                            if document.pages.indices.contains(mark.page) {
                                library.toggleBookmark(bookID: book.id, page: document.pages[mark.page])
                            }
                        }
                    }
                }
            }
        }.navigationTitle("目录与书签").navigationBarTitleDisplayMode(.inline)
    }

    private var searchResults: some View {
        List {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("输入关键词，搜索全书正文。").foregroundStyle(.secondary)
            } else {
                let results = document.search(search)
                Section("找到 \(results.count) 个分段（最多显示 100 个）") {
                    ForEach(results) { result in
                        Button { jump(result.id); panel = nil } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(result.id + 1) 页").font(.caption).foregroundStyle(.secondary)
                                Text(result.text).lineLimit(3).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
        }.searchable(text: $search, prompt: "搜索全书")
            .navigationTitle("搜索正文").navigationBarTitleDisplayMode(.inline)
    }
}
