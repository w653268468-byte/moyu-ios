import SwiftUI

@MainActor final class ReadingActivityStore: ObservableObject {
    static let shared = ReadingActivityStore()
    @Published private(set) var ledger = ReadingActivityLedger()
    @Published var failure: String?
    private let writer: DeferredSnapshotWriter
    private let file: URL
    private var locked = false
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) {
        let file = directory.appendingPathComponent("reading-activity.json"); self.file = file
        writer = DeferredSnapshotWriter(destination: file, backup: directory.appendingPathComponent("reading-activity.backup.json"))
        if FileManager.default.fileExists(atPath: file.path) {
            do { ledger = try JSONDecoder().decode(ReadingActivityLedger.self, from: Data(contentsOf: file)) }
            catch { locked = true; failure = "阅读记录无法读取，已保留原文件。" }
        }
    }
    func record(key: String, title: String, chapter: String, seconds: Double) {
        guard !locked else { return }
        ledger.record(bookKey: key, title: title, chapter: chapter, seconds: seconds)
        let snapshot = ledger
        writer.schedule(encode: { try JSONEncoder().encode(snapshot) }, failure: { [weak self] error in
            Task { @MainActor in self?.failure = "阅读记录保存失败：" + error.localizedDescription }
        })
    }
    func flush() { do { try writer.flush() } catch { failure = error.localizedDescription } }
    func reload() {
        writer.discardPendingAndWait()
        do { ledger = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(ReadingActivityLedger.self, from: Data(contentsOf: file)) : ReadingActivityLedger(); locked = false; failure = nil }
        catch { locked = true; failure = "阅读记录无法读取，已保留原文件。" }
    }
}

private struct ReadingActivityModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let key: String, title: String, chapter: String, position: String
    var paused: Bool
    @State private var lastTick: Date?
    @State private var lastInteraction = Date()
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    func body(content: Content) -> some View {
        content.onAppear { lastInteraction = Date(); lastTick = Date(); record(0) }
            .onReceive(timer) { _ in tick() }
            .onChange(of: position) { _, _ in lastInteraction = Date() }
            .onChange(of: scenePhase) { old, new in
                if old == .active { tick() }
                lastTick = new == .active ? Date() : nil
                if new == .active { lastInteraction = Date() }
                else { ReadingActivityStore.shared.flush() }
            }
            .onChange(of: paused) { old, new in
                if !old { tick() }; lastTick = new ? nil : Date()
            }
            .onDisappear { tick(); lastTick = nil; ReadingActivityStore.shared.flush() }
    }
    private func record(_ seconds: Double) { ReadingActivityStore.shared.record(key: key, title: title, chapter: chapter, seconds: seconds) }
    private func tick() {
        defer { lastTick = scenePhase == .active && !paused ? Date() : nil }
        guard let lastTick, !paused, Date().timeIntervalSince(lastInteraction) <= 120 else { return }
        record(max(0, min(30, Date().timeIntervalSince(lastTick))))
    }
}

extension View {
    func readingActivity(key: String, title: String, chapter: String, position: String, paused: Bool = false) -> some View {
        modifier(ReadingActivityModifier(key: key, title: title, chapter: chapter, position: position, paused: paused))
    }
}

struct ReadingHistoryView: View {
    @EnvironmentObject private var online: OnlineStore
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var activity = ReadingActivityStore.shared
    @State private var local: Book?
    @State private var remote: OnlineNovel?
    private var days: [String] { Array(Set(activity.ledger.entries.map(\.day))).sorted(by: >) }
    var body: some View {
        List {
            Section("阅读统计") {
                LabeledContent("累计阅读", value: "\(Int(activity.ledger.entries.reduce(0) { $0 + $1.seconds } / 60)) 分钟")
                LabeledContent("阅读天数", value: "\(days.count) 天")
                LabeledContent("读过的书", value: "\(Set(activity.ledger.entries.map(\.bookKey)).count) 本")
                Text("记录阅读页前台停留时长；切到后台、打开设置或两分钟没有翻动时暂停计时。历史条目点击后继续书架中的最新进度，最多保留 3000 条每日记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = activity.failure { Text(failure).foregroundStyle(.orange) }
            if days.isEmpty { ContentUnavailableView("还没有阅读记录", systemImage: "clock", description: Text("开始阅读后，这里会按日期显示书籍与阅读时长。")) }
            ForEach(days, id: \.self) { day in
                Section(day) {
                    ForEach(activity.ledger.entries.filter { $0.day == day }) { entry in
                        Button { open(entry) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(entry.chapter + " · \(Int(entry.seconds / 60)) 分钟").font(.caption).foregroundStyle(.secondary)
                                if !available(entry) { Text("该书已移出书架，阅读记录仍保留").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }.disabled(!available(entry))
                    }
                }
            }
        }.navigationTitle("阅读历史与统计").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $local) { NavigationStack { ReaderLoader(book: $0) } }
            .fullScreenCover(item: $remote) { OnlineReaderView(novel: $0) }
    }
    private func available(_ entry: ReadingActivity) -> Bool {
        library.books.contains { "local:" + $0.id.uuidString == entry.bookKey } || online.novels.contains { "online:" + $0.id == entry.bookKey }
    }
    private func open(_ entry: ReadingActivity) {
        local = library.books.first { "local:" + $0.id.uuidString == entry.bookKey }
        if local == nil { remote = online.novels.first { "online:" + $0.id == entry.bookKey } }
    }
}

struct ChapterUpdateCenter: View {
    @EnvironmentObject private var online: OnlineStore
    @State private var selected: OnlineNovel?
    var body: some View {
        List {
            Section { ShelfRefreshStatus() }
            Section("有未读更新") {
                let updated = online.novels.filter { !($0.unreadChapterIDs ?? []).isEmpty }
                if updated.isEmpty { Text("暂无未读更新，可下拉检查最新章节。").foregroundStyle(.secondary) }
                ForEach(updated) { book in
                    Button { selected = book } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title).foregroundStyle(.primary)
                            Text("未读 \(book.unreadChapterIDs?.count ?? 0) 章 · 最新：" + (book.lastChapter ?? book.chapters.last?.title ?? "未知")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !online.refreshFailures.isEmpty {
                Section("更新失败") {
                    Button("只重试失败的书籍") { Task { await online.refreshShelf(onlyFailed: true) } }.disabled(online.refreshingShelf)
                    ForEach(online.refreshFailures.keys.sorted(), id: \.self) { Text(online.refreshFailures[$0] ?? "").font(.caption).textSelection(.enabled) }
                }
            }
        }.navigationTitle("章节更新").navigationBarTitleDisplayMode(.inline)
            .refreshable { await online.refreshShelf() }
            .sheet(item: $selected) { NovelDetailView(novel: $0) }
    }
}

struct PreloadingPreferencesView: View {
    @AppStorage("reader.prefetch.mode") private var mode = "auto"
    @AppStorage("reader.prefetch.budgetMB") private var budget = 100
    var body: some View {
        Form {
            Section("章节预加载") {
                Picker("预加载方式", selection: $mode) { Text("智能 · 提前约五分钟").tag("auto"); Text("固定两章").tag("two"); Text("关闭").tag("off") }
                Picker("自动预取缓存上限", selection: $budget) { ForEach([50, 100, 200, 500], id: \.self) { Text("\($0) MB").tag($0) } }
                Text("根据近期翻页速度和章节长度，提前获取后续 2—6 章；同时最多请求两章。预算只清理自动预取的旧缓存，保留手动离线下载和当前阅读章节。受网站响应影响，不能保证所有章节都无需等待。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("预加载与缓存").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor final class DiscoveryPreferences: ObservableObject {
    static let shared = DiscoveryPreferences()
    private let defaults: UserDefaults
    @Published private(set) var hidden: [String]
    @Published private(set) var disliked: [String: String]
    @Published private(set) var favorites: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Self.read([String].self, key: "reader.discovery.hidden", defaults: defaults) ?? []
        disliked = Self.read([String: String].self, key: "reader.discovery.disliked", defaults: defaults) ?? [:]
        favorites = Self.read([String].self, key: "reader.discovery.favorites", defaults: defaults) ?? []
    }
    private func key(_ book: OnlineNovel) -> String { book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    func allows(_ book: OnlineNovel) -> Bool { !hidden.contains(key(book)) && disliked[key(book)] != DiscoveryCatalog.dayKey() }
    func hide(_ book: OnlineNovel, today: Bool) {
        let value = key(book)
        if today {
            disliked = disliked.filter { $0.value == DiscoveryCatalog.dayKey() }
            if disliked.count < 1000 { disliked[value] = DiscoveryCatalog.dayKey() }
        } else if !hidden.contains(value), hidden.count < 1000 { hidden.append(value) }
        save()
    }
    func unhide(_ key: String) { hidden.removeAll { $0 == key }; save() }
    func favorite(_ id: String) {
        if favorites.contains(id) { favorites.removeAll { $0 == id } }
        else if favorites.count < 100 { favorites.append(id) }
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(hidden) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "reader.discovery.hidden") }
        if let data = try? JSONEncoder().encode(disliked) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "reader.discovery.disliked") }
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(String(decoding: data, as: UTF8.self), forKey: "reader.discovery.favorites") }
    }
    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.string(forKey: key).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
    func reload() {
        hidden = Self.read([String].self, key: "reader.discovery.hidden", defaults: defaults) ?? []
        disliked = Self.read([String: String].self, key: "reader.discovery.disliked", defaults: defaults) ?? [:]
        favorites = Self.read([String].self, key: "reader.discovery.favorites", defaults: defaults) ?? []
    }
}

struct DiscoveryHiddenBooksView: View {
    @ObservedObject private var preferences = DiscoveryPreferences.shared
    var body: some View {
        List {
            Text("屏蔽按书名和作者匹配，对每日推荐、分类和榜单都生效。取消屏蔽后可重新显示；今日不感兴趣会在次日自动失效。")
                .font(.caption).foregroundStyle(.secondary)
            if preferences.hidden.isEmpty { Text("没有长期屏蔽的书籍").foregroundStyle(.secondary) }
            ForEach(preferences.hidden, id: \.self) { key in
                HStack { Text(key.replacingOccurrences(of: "|", with: " · ")); Spacer(); Button("取消屏蔽") { preferences.unhide(key) } }
            }
        }.navigationTitle("发现屏蔽管理").navigationBarTitleDisplayMode(.inline)
    }
}
