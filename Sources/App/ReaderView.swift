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

enum Paper: String, CaseIterable, Identifiable {
    case cream, white, green, night
    var id: String { rawValue }
    var name: String {
        switch self { case .cream: return "纸白"; case .white: return "纯白"; case .green: return "青瓷"; case .night: return "夜读" }
    }
    var background: Color {
        switch self {
        case .cream: return Color(red: 0.96, green: 0.94, blue: 0.88)
        case .white: return .white
        case .green: return Color(red: 0.87, green: 0.93, blue: 0.87)
        case .night: return Color(red: 0.10, green: 0.12, blue: 0.13)
        }
    }
    var ink: Color { self == .night ? Color(white: 0.78) : Color(white: 0.17) }
}

struct ReadingStyle: DynamicProperty {
    @AppStorage("reader.fontSize") var fontSize = 21.0
    @AppStorage("reader.lineSpacing") var lineSpacing = 10.0
    @AppStorage("reader.paper") var paperName = Paper.cream.rawValue
    @AppStorage("reader.serif") var serif = true
    var paper: Paper { Paper(rawValue: paperName) ?? .cream }
}

struct ReadingPreferences: View {
    private var style = ReadingStyle()
    var body: some View {
        Form {
            Section("纸张") {
                Picker("阅读主题", selection: Binding(get: { style.paperName }, set: { style.paperName = $0 })) {
                    ForEach(Paper.allCases) { Text($0.name).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            Section("排版") {
                HStack { Text("字号"); Spacer(); Text("\(Int(style.fontSize))").monospacedDigit() }
                Slider(value: Binding(get: { style.fontSize }, set: { style.fontSize = $0 }), in: 16...34, step: 1).accessibilityLabel("字号")
                HStack { Text("行距"); Spacer(); Text("\(Int(style.lineSpacing))").monospacedDigit() }
                Slider(value: Binding(get: { style.lineSpacing }, set: { style.lineSpacing = $0 }), in: 4...22, step: 1).accessibilityLabel("行距")
                Toggle("衬线字体", isOn: Binding(get: { style.serif }, set: { style.serif = $0 }))
            }
            Text("每页采用固定文本分段，调整字号不影响阅读位置。内容较长时可上下滚动。")
                .font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
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
    private var style = ReadingStyle()
    private var liveBook: Book { library.books.first { $0.id == book.id } ?? book }
    private var current: ReadingPage { document.pages[page] }
    private var marked: Bool { liveBook.bookmarks.contains { $0.page == page } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(document.chapters[current.chapter].title)
                        .font(.caption).opacity(0.6)
                    Text(current.text)
                        .font(.system(size: style.fontSize, design: style.serif ? .serif : .default))
                        .lineSpacing(style.lineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 26).padding(.vertical, 24).frame(maxWidth: 760)
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
        .preferredColorScheme(style.paper == .night ? .dark : .light)
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
        .onChange(of: page) { _, value in library.updatePosition(bookID: book.id, page: value) }
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
