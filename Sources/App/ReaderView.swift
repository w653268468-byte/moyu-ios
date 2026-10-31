import SwiftUI

struct ReaderLoader: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var document: BookDocument?
    @State private var failure: String?
    @State private var originalLayout = UserDefaults.standard.object(forKey: "reader.epubOriginalLayout") as? Bool ?? true

    var body: some View {
        Group {
            if book.originalEPUB == true && originalLayout {
                EPUBReaderLoader(book: book)
            } else if let document {
                ReaderView(book: book, document: document)
            } else if let failure {
                ContentUnavailableView("无法打开小说", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回") { dismiss() } } }
            } else { ProgressView("正在打开…") }
        }.task {
            guard book.originalEPUB != true || !originalLayout else { return }
            do { document = try await library.document(for: book) }
            catch { failure = error.localizedDescription }
        }
    }
}

private enum ReaderPanel: String, Identifiable {
    case contents, search, settings, progress, tools
    var id: String { rawValue }
}

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let document: BookDocument
    @State private var page = 0
    @State private var resumeOffset = 0
    @State private var resumeFraction: Double?
    @State private var navigationID = UUID()
    @State private var panel: ReaderPanel?
    @State private var search = ""
    @State private var cachedChapter = -1
    @State private var cachedSegments: [ReadingPage] = []
    @State private var cachedText = ""
    @AppStorage("reader.contentsDescending") private var contentsDescending = false
    @ObservedObject private var speech = ReaderSpeech.shared
    private var speechKey: String { "local:" + book.id.uuidString }
    private var style = ReadingStyle()
    private var liveBook: Book { library.books.first { $0.id == book.id } ?? book }
    private var current: ReadingPage { document.pages[page] }
    private var marked: Bool { liveBook.bookmarks.contains { $0.page == page } }

    init(book: Book, document: BookDocument) {
        self.book = book
        self.document = document
    }

    var body: some View {
        let readingID = navigationID
        VStack(spacing: 0) {
            ReadingTextPresentation(text: chapterText, title: document.chapters[current.chapter].title, book: book.title, origin: book.id.uuidString) { rendered in
             if style.paged {
                PagedReadingView(text: rendered.body.text, title: rendered.title,
                    resumeOffset: rendered.body.displayOffset(resumeOffset), onOffset: { saveOffset(rendered.body.originalOffset($0)) },
                    previousChapter: { chapterJump(current.chapter - 1, atEnd: true) },
                    nextChapter: { chapterJump(current.chapter + 1) },
                    toggleChrome: { style.fullScreen.toggle() }).id("\(current.chapter)-\(navigationID)")
            } else {
                ScrollReadingView(text: rendered.body.text, resumeOffset: rendered.body.displayOffset(resumeOffset), resumeFraction: resumeFraction,
                    onPosition: { offset, fraction in
                        guard readingID == navigationID else { return }
                        saveOffset(rendered.body.originalOffset(offset), fraction: fraction)
                    }, toggleChrome: { style.fullScreen.toggle() })
                    .id("\(current.chapter)-\(navigationID)")
            }
            }
            if !style.fullScreen {
                HStack {
                    Button {
                        chapterJump(current.chapter - 1, atEnd: true)
                    } label: { Label("上一章", systemImage: "chevron.left").frame(minHeight: 44) }
                        .disabled(current.chapter == 0)
                    Spacer()
                    Button { panel = .progress } label: {
                        Text("\(current.chapter + 1) / \(document.chapters.count) 章 · 跳转")
                            .font(.caption).monospacedDigit().frame(minHeight: 44)
                    }.accessibilityIdentifier("reader.progress")
                    Spacer()
                    Button {
                        chapterJump(current.chapter + 1)
                    } label: { Label("下一章", systemImage: "chevron.right").frame(minHeight: 44) }
                        .disabled(current.chapter == document.chapters.count - 1)
                }.font(.subheadline).padding(.horizontal, 16)
            }
        }
        .ignoresSafeArea(.container, edges: style.fullScreen && style.paged ? .all : [])
        .background(style.paper.background).foregroundStyle(style.paper.ink)
        .preferredColorScheme(style.paper.isDark ? .dark : .light)
        .modifier(ReadingAppearance())
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(style.fullScreen)
        .readingActivity(key: "local:" + book.id.uuidString, title: book.title, chapter: document.chapters[current.chapter].title, position: "\(page)-\(resumeOffset)", paused: panel != nil)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !style.fullScreen { readerControls }
        }
        .onAppear {
            page = min(max(0, liveBook.page), document.pages.count - 1)
            cacheChapter()
            resumeOffset = liveBook.textOffset ?? offsetForSegment(page)
            resumeFraction = liveBook.scrollFraction
            navigationID = UUID()
        }
        .onChange(of: page) { old, value in
            if document.pages[old].chapter != document.pages[value].chapter && speech.owner == speechKey && speech.chapterIndex != document.pages[value].chapter { speech.stop() }
        }
        .onChange(of: current.chapter) { _, _ in cacheChapter() }
        .onChange(of: speech.chapterIndex) { _, value in if speech.active && speech.owner == speechKey && document.chapters.indices.contains(value) { chapterJump(value) } }
        .onChange(of: style.paged) { _, _ in
            resumeOffset = liveBook.textOffset ?? offsetForSegment(page)
            resumeFraction = liveBook.scrollFraction
            navigationID = UUID()
        }
        .alert("听书提示", isPresented: Binding(get: { speech.message != nil }, set: { if !$0 { speech.message = nil } })) { Button("知道了") { speech.message = nil } } message: { Text(speech.message ?? "") }
        .sheet(item: $panel) { selected in
          if selected == .progress {
            ReadingProgressPicker(titles: document.chapters.map(\.title), current: current.chapter) { chapter in
                jump(document.chapters[chapter].firstPage); panel = nil
            }
          } else {
            NavigationStack {
                Group {
                    switch selected {
                    case .settings: ReadingPreferences()
                    case .contents: contents
                    case .search: searchResults
                    case .progress: EmptyView()
                    case .tools: ReplacementRulesView()
                    }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { panel = nil } } }
            }
          }
        }
    }

    private var readerControls: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("返回书架")
            Text(book.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button { panel = .contents } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("目录与书签")
            Button { panel = .settings } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }.accessibilityLabel("阅读设置")
            Menu {
                Button(marked ? "移除书签" : "添加书签", systemImage: marked ? "bookmark.fill" : "bookmark") { library.toggleBookmark(bookID: book.id, page: current) }
                Button("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right") { style.fullScreen = true }
                Button(speech.active && speech.owner == speechKey ? (speech.paused ? "继续听书" : "暂停听书") : "从当前位置连续听书", systemImage: "speaker.wave.2", action: startSpeech)
                if speech.active { Button("停止朗读", systemImage: "stop.circle") { speech.stop() } }
                Button("搜索正文", systemImage: "magnifyingglass") { panel = .search }
                Button("替换净化", systemImage: "text.badge.minus") { panel = .tools }
                Button("进度跳转", systemImage: "slider.horizontal.3") { panel = .progress }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("阅读菜单")
        }.padding(.horizontal, 8).foregroundStyle(style.paper.ink).background(style.paper.background)
    }

    private var chapterSegments: [ReadingPage] { cachedChapter == current.chapter ? cachedSegments : document.pages.filter { $0.chapter == current.chapter } }
    private func cacheChapter() {
        cachedSegments = document.pages.filter { $0.chapter == current.chapter }
        cachedText = cachedSegments.map { TextPagination.readingText($0.text) }.joined(separator: "\n")
        cachedChapter = current.chapter
    }
    private func startSpeech() {
        let data = document, id = book.id, store = library
        let presenter = SpeechTextPresentation(), name = book.title
        speech.start(owner: speechKey, title: book.title, chapter: current.chapter, offset: resumeOffset, loader: { index in
            guard data.chapters.indices.contains(index) else { return nil }
            return try await presenter.prepare(index: index, title: data.chapters[index].title, text: data.pages.filter { $0.chapter == index }.map { TextPagination.readingText($0.text) }.joined(separator: "\n"), book: name, origin: id.uuidString)
        }, positionMap: { presenter.offset(chapter: $0, value: $1, original: $2) }, progress: { chapter, offset in
            var start = 0, page = data.chapters[chapter].firstPage
            for segment in data.pages where segment.chapter == chapter {
                if start > offset { break }; page = segment.id; start += (TextPagination.readingText(segment.text) as NSString).length + 1
            }
            store.updatePosition(bookID: id, page: page, textOffset: offset)
        })
    }
    private var chapterText: String { cachedChapter == current.chapter ? cachedText : chapterSegments.map { TextPagination.readingText($0.text) }.joined(separator: "\n") }

    private func offsetForSegment(_ target: Int) -> Int {
        let chapter = document.pages[target].chapter
        return document.pages.filter { $0.chapter == chapter && $0.id < target }
            .reduce(0) { $0 + (TextPagination.readingText($1.text) as NSString).length + 1 }
    }
    private func saveOffset(_ offset: Int, fraction: Double? = nil) {
        var start = 0
        var segment = chapterSegments.first?.id ?? page
        for item in chapterSegments {
            if start > offset { break }
            segment = item.id
            start += (TextPagination.readingText(item.text) as NSString).length + 1
        }
        page = segment
        library.updatePosition(bookID: book.id, page: segment, textOffset: offset, scrollFraction: fraction)
    }
    private func chapterJump(_ chapter: Int, atEnd: Bool = false) {
        guard document.chapters.indices.contains(chapter) else { return }
        page = document.chapters[chapter].firstPage
        resumeFraction = 0
        resumeOffset = atEnd ? Int.max : 0
        navigationID = UUID()
    }
    private func jump(_ target: Int) {
        page = min(max(0, target), document.pages.count - 1)
        resumeFraction = 0
        resumeOffset = offsetForSegment(page)
        navigationID = UUID()
        library.updatePosition(bookID: book.id, page: page, textOffset: resumeOffset)
    }

    private var contents: some View {
        ScrollViewReader { proxy in
         List {
            Section("目录 · \(document.chapters.count) 章") {
                ForEach(ChapterOrder.indices(count: document.chapters.count, descending: contentsDescending), id: \.self) { position in
                    let chapter = document.chapters[position]
                    Button { jump(chapter.firstPage); panel = nil } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if chapter.id == current.chapter { Image(systemName: "speaker.wave.1") }
                        }
                    }.id(position).accessibilityIdentifier("catalog.chapter.\(position)").accessibilityValue(position == current.chapter ? "当前章节" : "")
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
         }.safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                ChapterOrderPicker(descending: $contentsDescending)
                HStack {
                    Text("共 \(document.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("定位当前章") { proxy.scrollTo(current.chapter, anchor: .center) }.accessibilityIdentifier("catalog.current")
                }
            }.padding(12).background(.bar)
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
