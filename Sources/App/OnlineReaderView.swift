import SwiftUI

struct OnlineReaderView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    let novel: OnlineNovel
    @State private var index: Int
    @State private var text = ""
    @State private var failure: String?
    @State private var loading = true
    @State private var showContents = false
    @State private var showSettings = false
    @State private var official = false
    @State private var retry = 0
    private var style = ReadingStyle()

    init(novel: OnlineNovel) {
        self.novel = novel
        _index = State(initialValue: min(max(0, novel.chapterIndex), max(0, novel.chapters.count - 1)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if novel.chapters.isEmpty {
                    ContentUnavailableView("章节目录为空", systemImage: "list.bullet")
                } else if loading {
                    Spacer(); ProgressView("正在获取正文…"); Spacer()
                } else if let failure {
                    ContentUnavailableView {
                        Label("无法读取这一章", systemImage: "wifi.exclamationmark")
                    } description: { Text(failure) } actions: {
                        Button("重试") { retry += 1 }
                        Button("官方网页", systemImage: "safari") { official = true }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            Text(novel.chapters[index].title).font(.title2.weight(.medium)).padding(.bottom, 8)
                            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.system(size: style.fontSize, design: style.serif ? .serif : .default))
                                    .lineSpacing(style.lineSpacing).textSelection(.enabled)
                            }
                            Text(index == novel.chapters.count - 1 ? "已到目录最后一章" : "本章完 · 点击右下角继续")
                                .font(.caption).opacity(0.5).frame(maxWidth: .infinity).padding(.vertical, 25)
                        }.padding(26).frame(maxWidth: 760).frame(maxWidth: .infinity, alignment: .center)
                    }.id(index)
                }
                HStack {
                    Button { index -= 1 } label: { Label("上一章", systemImage: "chevron.left").frame(minHeight: 44) }
                        .disabled(index <= 0)
                    Spacer()
                    Text("\(novel.chapters.isEmpty ? 0 : index + 1) / \(novel.chapters.count)")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button { index += 1 } label: { Label("下一章", systemImage: "chevron.right").frame(minHeight: 44) }
                        .disabled(index >= novel.chapters.count - 1)
                }.font(.subheadline).padding(.horizontal, 18)
            }.background(style.paper.background).foregroundStyle(style.paper.ink)
                .preferredColorScheme(style.paper == .night ? .dark : .light)
                .navigationTitle(novel.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("返回书架")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { official = true } label: { Image(systemName: "safari") }.accessibilityLabel("打开官方网页")
                        Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("章节目录")
                        Button { showSettings = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("阅读设置")
                    }
                }
                .task(id: "\(index)-\(retry)") {
                    guard novel.chapters.indices.contains(index) else { loading = false; return }
                    let target = index
                    loading = true; failure = nil; text = ""
                    do {
                        let fetched = try await online.chapter(novel.chapters[target], sourceID: novel.sourceID)
                        try Task.checkCancellation()
                        guard target == index else { return }
                        text = fetched
                        online.position(novel, index: target)
                        loading = false
                    } catch {
                        guard !Task.isCancelled, target == index else { return }
                        failure = error.localizedDescription
                        loading = false
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        ReadingPreferences().toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
                        }
                    }
                }
                .sheet(isPresented: $official) {
                    OfficialWebView(url: novel.chapters.indices.contains(index) ? novel.chapters[index].url : novel.url)
                }
                .sheet(isPresented: $showContents) {
                    NavigationStack {
                        ScrollViewReader { proxy in
                            List(Array(novel.chapters.enumerated()), id: \.element.id) { number, chapter in
                                Button { index = number; showContents = false } label: {
                                    HStack {
                                        Text(chapter.title).foregroundStyle(.primary)
                                        Spacer()
                                        if number == index { Image(systemName: "checkmark") }
                                    }
                                }.id(number)
                            }.onAppear { proxy.scrollTo(index, anchor: .center) }
                        }.navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
                    }
                }
        }
    }
}
