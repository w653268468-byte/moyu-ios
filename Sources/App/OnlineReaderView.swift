import SwiftUI

struct OnlineReaderView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    @State private var novel: OnlineNovel
    @State private var index: Int
    @State private var text = ""
    @State private var failure: String?
    @State private var loading = true
    @State private var showContents = false
    @State private var showSettings = false
    @State private var showProgress = false
    @State private var showTextTools = false
    @State private var updatingCatalog = false
    @State private var catalogMessage: String?
    @State private var catalogTask: Task<Void, Never>?
    @State private var official = false
    @State private var retry = 0
    @State private var showSourceSwitch = false
    @State private var switching = false
    @State private var switchStatus = ""
    @State private var switchTask: Task<Void, Never>?
    @State private var switchID = UUID()
    @State private var resumeOffset = 0
    @State private var resumeFraction: Double?
    @State private var openAtEnd = false
    @State private var pendingOffset: Int?
    @State private var positionRevision = UUID()
    @State private var contentsTab = "目录"
    @State private var chapterFilter = ""
    @AppStorage("reader.contentsDescending") private var contentsDescending = false
    @State private var editingMark: OnlineReadingMark?
    @ObservedObject private var speech = ReaderSpeech.shared
    private var speechKey: String { "online:" + novel.id }
    private var style = ReadingStyle()
    private var marks: [OnlineReadingMark] { (online.novels.first { $0.id == novel.id && $0.sourceID == novel.sourceID } ?? novel).readingMarks ?? [] }

    init(novel: OnlineNovel) {
        _novel = State(initialValue: novel)
        _index = State(initialValue: min(max(0, novel.chapterIndex), max(0, novel.chapters.count - 1)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if switching {
                    HStack { ProgressView(); Text(switchStatus).font(.caption); Spacer(); Button("取消换源") { cancelSwitch() } }.padding(12)
                }
                if novel.chapters.isEmpty {
                    ContentUnavailableView("章节目录为空", systemImage: "list.bullet")
                } else if loading {
                    Spacer(); ProgressView("正在获取正文…"); Spacer()
                } else if let failure {
                    ContentUnavailableView {
                        Label("无法读取这一章", systemImage: "wifi.exclamationmark")
                    } description: { Text(failure) } actions: {
                        Button("重试") { retry += 1 }
                        Button("网页登录 / 验证", systemImage: "safari") { official = true }
                        Button("手动换源", systemImage: "arrow.triangle.2.circlepath") { showSourceSwitch = true }
                    }
                } else {
                  ReadingTextPresentation(text: text, title: novel.chapters[index].title, book: novel.title, origin: novel.sourceID) { rendered in
                   let readingIndex = index
                   if style.paged {
                    PagedReadingView(text: rendered.body.text, title: rendered.title, resumeOffset: rendered.body.displayOffset(resumeOffset),
                        onOffset: { guard index == readingIndex else { return }; let original = rendered.body.originalOffset($0); resumeOffset = original; online.position(novel, index: index, textOffset: original) },
                        previousChapter: { if index > 0 { openAtEnd = true; index -= 1 } },
                        nextChapter: { if index + 1 < novel.chapters.count { index += 1 } },
                        toggleChrome: { style.fullScreen.toggle() }).id(index)
                } else {
                    ScrollReadingView(text: rendered.body.text, resumeOffset: rendered.body.displayOffset(resumeOffset), resumeFraction: resumeFraction,
                        onPosition: { offset, fraction in
                            guard index == readingIndex else { return }
                            let original = rendered.body.originalOffset(offset)
                            resumeOffset = original; resumeFraction = fraction
                            online.position(novel, index: index, textOffset: original, scrollFraction: fraction)
                        }, toggleChrome: { style.fullScreen.toggle() }).id(index)
                }
                  }
                }
                if !style.fullScreen { HStack {
                    Button { index -= 1 } label: { Label("上一章", systemImage: "chevron.left").frame(minHeight: 44) }
                        .disabled(index <= 0)
                    Spacer()
                    Button { showProgress = true } label: {
                        Text("\(novel.chapters.isEmpty ? 0 : index + 1) / \(novel.chapters.count) · 跳转")
                            .font(.caption).monospacedDigit().frame(minHeight: 44)
                    }.accessibilityIdentifier("reader.progress")
                    Spacer()
                    Button { index += 1 } label: { Label("下一章", systemImage: "chevron.right").frame(minHeight: 44) }
                        .disabled(index >= novel.chapters.count - 1)
                }.font(.subheadline).padding(.horizontal, 18) }
            }.ignoresSafeArea(.container, edges: style.fullScreen && style.paged ? .all : [])
                .background(style.paper.background).foregroundStyle(style.paper.ink)
                .preferredColorScheme(style.paper.isDark ? .dark : .light)
                .modifier(ReadingAppearance())
                .navigationTitle(novel.title).navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden(style.fullScreen)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !style.fullScreen { readerControls }
                }
                .task(id: "\(novel.sourceID)-\(index)-\(retry)-\(positionRevision)") {
                    guard novel.chapters.indices.contains(index) else { loading = false; return }
                    if speech.owner == speechKey && speech.chapterIndex != index { speech.stop() }
                    let target = index
                    loading = true; failure = nil; text = ""
                    do {
                        let fetched = try await online.chapter(novel.chapters[target], sourceID: novel.sourceID)
                        try Task.checkCancellation()
                        guard target == index else { return }
                        let saved = online.novels.first { $0.id == novel.id } ?? novel
                        resumeOffset = pendingOffset ?? (openAtEnd ? Int.max : (saved.chapterIndex == target ? (saved.textOffset ?? 0) : 0))
                        resumeFraction = pendingOffset == nil && !openAtEnd && saved.chapterIndex == target ? saved.scrollFraction : nil
                        pendingOffset = nil
                        openAtEnd = false
                        text = fetched
                        online.position(novel, index: target)
                        loading = false
                    } catch {
                        guard !Task.isCancelled, target == index else { return }
                        failure = error.localizedDescription
                        loading = false
                        if style.autoChangeSource { startSwitch() }
                    }
                }
                .onDisappear { cancelSwitch(); catalogTask?.cancel() }
                .onChange(of: index) { _, value in cancelSwitch(); if speech.owner == speechKey && speech.chapterIndex != value { speech.stop() } }
                .onChange(of: speech.chapterIndex) { _, value in if speech.active && speech.owner == speechKey && novel.chapters.indices.contains(value) { index = value } }
                .onChange(of: showSourceSwitch) { _, shown in if shown { cancelSwitch() } }
                .sheet(isPresented: $showSourceSwitch) {
                    SourceSwitchView(novel: novel, chapterIndex: index, onChanged: applyReplacement)
                }
                .alert("听书提示", isPresented: Binding(get: { speech.message != nil }, set: { if !$0 { speech.message = nil } })) { Button("知道了") { speech.message = nil } } message: { Text(speech.message ?? "") }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        ReadingPreferences().toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
                        }
                    }
                }
                .sheet(isPresented: $showProgress) {
                    ReadingProgressPicker(titles: novel.chapters.map(\.title), current: index) { jumpToChapter($0) }
                }
                .sheet(isPresented: $showTextTools) { NavigationStack { ReplacementRulesView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showTextTools = false } } } } }
                .sheet(isPresented: $official, onDismiss: { retry += 1 }) {
                    OfficialWebView(url: novel.chapters.indices.contains(index) ? novel.chapters[index].url : novel.url)
                }
                .sheet(isPresented: $showContents) {
                    NavigationStack {
                        ScrollViewReader { proxy in
                            List {
                              if contentsTab == "目录" {
                               ForEach(ChapterOrder.indices(count: novel.chapters.count, descending: contentsDescending).filter { chapterFilter.isEmpty || novel.chapters[$0].title.localizedCaseInsensitiveContains(chapterFilter) }, id: \.self) { number in
                                let chapter = novel.chapters[number]
                                Button { pendingOffset = 0; positionRevision = UUID(); index = number; showContents = false } label: {
                                    HStack {
                                        Text(chapter.title).foregroundStyle(.primary)
                                        Spacer()
                                        if number == index { Image(systemName: "checkmark") }
                                    }
                                }.id(number).accessibilityIdentifier("catalog.chapter.\(number)").accessibilityValue(number == index ? "当前章节" : "")
                               }
                              } else {
                                if marks.isEmpty { Text("阅读页点书签按钮保存当前位置，支持添加备注。").foregroundStyle(.secondary) }
                                ForEach(marks) { mark in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Button { openMark(mark) } label: { VStack(alignment: .leading, spacing: 5) { Text(mark.chapterTitle).font(.headline); Text(mark.excerpt).font(.subheadline).lineLimit(3) }.foregroundStyle(.primary) }
                                        if !mark.note.isEmpty { Text(mark.note).font(.caption).foregroundStyle(.secondary) }
                                        Button("编辑备注") { editingMark = mark }.font(.caption).buttonStyle(.borderless)
                                    }.swipeActions { Button("删除", role: .destructive) { do { try online.removeMark(mark.id, in: novel) } catch { failure = error.localizedDescription } } }
                                }
                              }
                            }.safeAreaInset(edge: .top, spacing: 0) {
                                VStack(spacing: 8) {
                                    Picker("目录与书签", selection: $contentsTab) { Text("目录").tag("目录"); Text("书签 · \(marks.count)").tag("书签") }.pickerStyle(.segmented)
                                    if contentsTab == "目录" {
                                        ChapterOrderPicker(descending: $contentsDescending)
                                        HStack {
                                            Button("定位当前章") { chapterFilter = ""; proxy.scrollTo(index, anchor: .center) }.accessibilityIdentifier("catalog.current")
                                            Spacer()
                                            Button(updatingCatalog ? "正在更新…" : "更新目录") { updateCatalog() }
                                                .disabled(updatingCatalog || switching).accessibilityIdentifier("catalog.refresh")
                                        }
                                        if let catalogMessage { Text(catalogMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    }
                                }.padding(12).background(.bar)
                            }
                        }.searchable(text: $chapterFilter, prompt: "筛选章节标题").navigationTitle("目录与书签").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
                            .sheet(item: $editingMark) { mark in OnlineMarkEditor(mark: mark) { updated in do { try online.saveMark(updated, in: novel) } catch { failure = error.localizedDescription } } }
                    }
                }
        }
    }
    private var readerControls: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("返回书架")
            Text(novel.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("章节目录")
            Button { showSettings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }.accessibilityLabel("阅读设置")
            Menu {
                Button("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right") { style.fullScreen = true }
                Button("进度跳转", systemImage: "slider.horizontal.3") { showProgress = true }
                Button("替换净化", systemImage: "text.badge.minus") { showTextTools = true }
                Button(updatingCatalog ? "正在更新目录…" : "更新目录", systemImage: "arrow.clockwise") { updateCatalog() }.disabled(updatingCatalog || switching)
                Button(speech.active && speech.owner == speechKey ? (speech.paused ? "继续听书" : "暂停听书") : "从当前位置连续听书", systemImage: "speaker.wave.2", action: startSpeech).disabled(loading || text.isEmpty)
                if speech.active { Button("停止朗读", systemImage: "stop.circle") { speech.stop() } }
                Button("手动选择书源和章节") { showSourceSwitch = true }
                Button("自动寻找可用书源") { startSwitch() }.disabled(switching)
                Button("打开官方网页", systemImage: "safari") { official = true }
                Button("添加在线书签", systemImage: "bookmark.badge.plus") {
                    guard novel.chapters.indices.contains(index) else { return }
                    do { try online.saveMark(OnlineReadingMark(chapter: novel.chapters[index], index: index, offset: resumeOffset, text: TextPagination.readingText(text)), in: novel) }
                    catch { failure = error.localizedDescription }
                }.disabled(loading || text.isEmpty)
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("阅读菜单")
        }.padding(.horizontal, 8).foregroundStyle(style.paper.ink).background(style.paper.background)
    }

    private func jumpToChapter(_ target: Int) {
        guard novel.chapters.indices.contains(target) else { return }
        if speech.owner == speechKey { speech.stop() }
        pendingOffset = 0; openAtEnd = false; resumeFraction = nil
        index = target; positionRevision = UUID()
        online.position(novel, index: target, textOffset: 0, scrollFraction: 0)
    }

    private func updateCatalog() {
        guard !updatingCatalog, !switching else { return }
        guard let source = online.sources.first(where: { $0.id == novel.sourceID }) else {
            catalogMessage = "原书源已移除，无法更新；已下载章节仍可阅读。"; return
        }
        let original = novel
        updatingCatalog = true; catalogMessage = nil
        catalogTask = Task {
            defer { updatingCatalog = false }
            do {
                let worker = await online.client.isolatedWorker()
                let updated = try await worker.catalog(original, source: source)
                try Task.checkCancellation()
                guard novel.id == original.id, novel.sourceID == original.sourceID else { return }
                let activeChapter = novel.chapters.indices.contains(index) ? novel.chapters[index] : nil
                guard !updated.chapters.isEmpty else { throw SourceError.message("网站返回空目录") }
                var current = online.novels.first(where: { $0.id == novel.id && $0.sourceID == novel.sourceID }) ?? novel
                current.chapterIndex = index; current.textOffset = resumeOffset; current.scrollFraction = resumeFraction
                let refreshed = updated.refreshedCatalog(from: current, at: Date())
                if let activeChapter, let destination = updated.chapters.firstIndex(where: { $0.id == activeChapter.id }) {
                    if destination != index { pendingOffset = resumeOffset }
                } else {
                    catalogMessage = "目录已更新，但当前章节已移除；请选择章节继续阅读。"
                    pendingOffset = 0; positionRevision = UUID()
                }
                try online.keep(refreshed)
                novel = refreshed; index = refreshed.chapterIndex
                if catalogMessage == nil {
                    let oldIDs = Set(original.chapters.map(\.id))
                    let added = updated.chapters.filter { !oldIDs.contains($0.id) }.count
                    catalogMessage = added > 0 ? "已更新，新增 \(added) 章，共 \(updated.chapters.count) 章。" : "目录已更新，共 \(updated.chapters.count) 章。"
                }
            } catch { if !Task.isCancelled { catalogMessage = "更新失败：\(error.localizedDescription)。已保留原目录，可重试或换源。" } }
        }
    }

    private func openMark(_ mark: OnlineReadingMark) {
        guard let target = mark.destination(in: novel.chapters) else { failure = "当前书源找不到书签对应的章节，请换回原书源或手动选择章节。"; return }
        if speech.owner == speechKey { speech.stop() }
        pendingOffset = mark.textOffset; index = target; positionRevision = UUID(); showContents = false
    }
    private func startSpeech() {
        let book = novel, store = online
        let presenter = SpeechTextPresentation()
        speech.start(owner: speechKey, title: novel.title, chapter: index, offset: resumeOffset, loader: { chapter in
            guard book.chapters.indices.contains(chapter) else { return nil }
            let text = try await store.chapter(book.chapters[chapter], sourceID: book.sourceID)
            return try await presenter.prepare(index: chapter, title: book.chapters[chapter].title, text: text, book: book.title, origin: book.sourceID)
        }, positionMap: { presenter.offset(chapter: $0, value: $1, original: $2) }, progress: { chapter, offset in store.position(book, index: chapter, textOffset: offset) })
    }
    private func cancelSwitch() {
        switchTask?.cancel(); switchID = UUID(); switching = false; switchStatus = ""
    }
    private func applyReplacement(_ updated: OnlineNovel) {
        speech.stop()
        novel = updated; index = updated.chapterIndex
        resumeOffset = updated.textOffset ?? 0; resumeFraction = updated.scrollFraction
        text = ""; failure = nil; loading = true
    }
    private func startSwitch() {
        guard !switching, novel.chapters.indices.contains(index) else { return }
        let original = novel, target = index
        switchID = UUID(); let token = switchID
        switching = true; switchStatus = "正在查找同书名、同作者的替代书源…"
        switchTask = Task {
            defer { if switchID == token { switching = false; switchStatus = "" } }
            do {
                let result = try await SourceSwitcher(client: online.client).automatic(original, chapterIndex: target, sources: online.sources) { message in
                    await MainActor.run { if switchID == token { switchStatus = message } }
                }
                try Task.checkCancellation()
                guard token == switchID, index == target, novel.sourceID == original.sourceID else { return }
                try online.commitReplacement(original, replacement: result)
                applyReplacement(result.novel)
            } catch { if !Task.isCancelled && token == switchID { failure = error.localizedDescription } }
        }
    }

}

private struct OnlineMarkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var mark: OnlineReadingMark
    let save: (OnlineReadingMark) -> Void
    var body: some View {
        NavigationStack {
            Form { Section(mark.chapterTitle) { Text(mark.excerpt); TextField("书签备注", text: $mark.note, axis: .vertical).lineLimit(4...10) } }
                .navigationTitle("书签备注").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { mark.note = String(mark.note.prefix(4000)); save(mark); dismiss() } } }
        }
    }
}
