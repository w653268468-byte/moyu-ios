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
                } else if style.paged {
                    PagedReadingView(text: text, title: novel.chapters[index].title, resumeOffset: resumeOffset,
                        onOffset: { resumeOffset = $0; online.position(novel, index: index, textOffset: $0) },
                        previousChapter: { if index > 0 { openAtEnd = true; index -= 1 } },
                        nextChapter: { if index + 1 < novel.chapters.count { index += 1 } },
                        toggleChrome: { style.fullScreen.toggle() }).id(index)
                } else {
                    let readingIndex = index
                    ScrollReadingView(text: text, resumeOffset: resumeOffset, resumeFraction: resumeFraction,
                        onPosition: { offset, fraction in
                            guard index == readingIndex else { return }
                            resumeOffset = offset; resumeFraction = fraction
                            online.position(novel, index: index, textOffset: offset, scrollFraction: fraction)
                        }, toggleChrome: { style.fullScreen.toggle() }).id(index)
                }
                if !style.fullScreen { HStack {
                    Button { index -= 1 } label: { Label("上一章", systemImage: "chevron.left").frame(minHeight: 44) }
                        .disabled(index <= 0)
                    Spacer()
                    Text("\(novel.chapters.isEmpty ? 0 : index + 1) / \(novel.chapters.count)")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button { index += 1 } label: { Label("下一章", systemImage: "chevron.right").frame(minHeight: 44) }
                        .disabled(index >= novel.chapters.count - 1)
                }.font(.subheadline).padding(.horizontal, 18) }
            }.background(style.paper.background).foregroundStyle(style.paper.ink)
                .preferredColorScheme(style.paper.isDark ? .dark : .light)
                .modifier(ReadingAppearance())
                .navigationTitle(novel.title).navigationBarTitleDisplayMode(.inline)
                .toolbar(style.fullScreen ? .hidden : .visible, for: .navigationBar)
                .statusBarHidden(style.fullScreen)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("返回书架")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right") { style.fullScreen = true }
                            Button(speech.active && speech.owner == speechKey ? (speech.paused ? "继续听书" : "暂停听书") : "从当前位置连续听书", systemImage: "speaker.wave.2", action: startSpeech).disabled(loading || text.isEmpty)
                            if speech.active { Button("停止朗读", systemImage: "stop.circle") { speech.stop() } }
                        } label: { Image(systemName: "speaker.wave.2") }
                        Menu {
                            Button("手动选择书源和章节") { showSourceSwitch = true }
                            Button("自动寻找可用书源") { startSwitch() }.disabled(switching)
                        } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        Button { official = true } label: { Image(systemName: "safari") }.accessibilityLabel("打开官方网页")
                        Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("章节目录")
                        Button { showSettings = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("阅读设置")
                        Button {
                            guard novel.chapters.indices.contains(index) else { return }
                            do { try online.saveMark(OnlineReadingMark(chapter: novel.chapters[index], index: index, offset: resumeOffset, text: text), in: novel) }
                            catch { failure = error.localizedDescription }
                        } label: { Image(systemName: "bookmark.badge.plus") }.accessibilityLabel("添加在线书签").disabled(loading || text.isEmpty)
                    }
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
                .onDisappear { cancelSwitch() }
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
                .sheet(isPresented: $official, onDismiss: { retry += 1 }) {
                    OfficialWebView(url: novel.chapters.indices.contains(index) ? novel.chapters[index].url : novel.url)
                }
                .sheet(isPresented: $showContents) {
                    NavigationStack {
                        ScrollViewReader { proxy in
                            List {
                              Picker("目录与书签", selection: $contentsTab) { Text("目录").tag("目录"); Text("书签 · \(marks.count)").tag("书签") }.pickerStyle(.segmented)
                              if contentsTab == "目录" {
                               ForEach(Array(novel.chapters.enumerated()).filter { chapterFilter.isEmpty || $0.element.title.localizedCaseInsensitiveContains(chapterFilter) }, id: \.element.id) { number, chapter in
                                Button { pendingOffset = 0; positionRevision = UUID(); index = number; showContents = false } label: {
                                    HStack {
                                        Text(chapter.title).foregroundStyle(.primary)
                                        Spacer()
                                        if number == index { Image(systemName: "checkmark") }
                                    }
                                }.id(number)
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
                            }.onAppear { if contentsTab == "目录" { proxy.scrollTo(index, anchor: .center) } }
                        }.searchable(text: $chapterFilter, prompt: "筛选章节标题").navigationTitle("目录与书签").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
                            .sheet(item: $editingMark) { mark in OnlineMarkEditor(mark: mark) { updated in do { try online.saveMark(updated, in: novel) } catch { failure = error.localizedDescription } } }
                    }
                }
        }
    }
    private func openMark(_ mark: OnlineReadingMark) {
        guard let target = mark.destination(in: novel.chapters) else { failure = "当前书源找不到书签对应的章节，请换回原书源或手动选择章节。"; return }
        if speech.owner == speechKey { speech.stop() }
        pendingOffset = mark.textOffset; index = target; positionRevision = UUID(); showContents = false
    }
    private func startSpeech() {
        let book = novel, store = online
        speech.start(owner: speechKey, title: novel.title, chapter: index, offset: resumeOffset, loader: { chapter in
            guard book.chapters.indices.contains(chapter) else { return nil }
            return (book.chapters[chapter].title, try await store.chapter(book.chapters[chapter], sourceID: book.sourceID))
        }, progress: { chapter, offset in store.position(book, index: chapter, textOffset: offset) })
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
