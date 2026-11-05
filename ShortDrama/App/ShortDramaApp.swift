import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct Episode: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var url: URL
}
struct Drama: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String?
    var poster: URL?
    var episodes: [Episode]
}
struct Feed: Codable {
    var name: String
    var dramas: [Drama]
}
struct Source: Codable, Identifiable {
    var id = UUID()
    var url: URL?
    var feed: Feed
    var updated = Date()
    var error: String?
}
struct Saved: Codable {
    var sources: [Source] = []
    var favorites: Set<String> = []
    var watched: [String: String] = [:]
}
enum FeedError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
@MainActor final class Library: ObservableObject {
    @Published var state = Saved()
    @Published var busy = false
    @Published var message: String?
    private let file: URL
    init() {
        file = URL.documentsDirectory.appending(path: "library.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            }
        } catch { message = "本地数据读取失败：\(error.localizedDescription)" }
    }
    func save() {
        do { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
        catch { message = "保存失败：\(error.localizedDescription)" }
    }
    func key(_ source: Source, _ drama: Drama) -> String { "\(source.id)/\(drama.id)" }
    func decode(_ data: Data) throws -> Feed {
        guard data.count <= 5_000_000 else { throw FeedError.invalid("视频源超过 5 MB") }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard !feed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(feed.dramas.map(\.id)).count == feed.dramas.count else {
            throw FeedError.invalid("源名称为空或剧集 ID 重复")
        }
        for drama in feed.dramas {
            guard !drama.id.isEmpty, !drama.title.isEmpty,
                  Set(drama.episodes.map(\.id)).count == drama.episodes.count,
                  drama.episodes.allSatisfy({ !$0.id.isEmpty && $0.url.scheme == "https" && $0.url.host != nil }) else {
                throw FeedError.invalid("剧集字段无效、分集 ID 重复或播放地址不是 HTTPS")
            }
        }
        return feed
    }
    func fetch(_ url: URL) async throws -> Feed {
        guard url.scheme == "https", url.host != nil else { throw FeedError.invalid("请输入 HTTPS 视频源地址") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else { throw FeedError.invalid("源服务器返回错误或不安全重定向") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 5_000_000 else { throw FeedError.invalid("视频源超过 5 MB") }
            data.append(byte)
        }
        return try decode(data)
    }
    func importSource(text: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("{") { add(try decode(Data(text.utf8)), url: nil) }
            else {
                guard let url = URL(string: text) else { throw FeedError.invalid("地址格式错误") }
                add(try await fetch(url), url: url)
            }
        } catch { message = error.localizedDescription }
    }
    func add(_ feed: Feed, url: URL?) {
        if let url, let index = state.sources.firstIndex(where: { $0.url == url }) {
            state.sources[index].feed = feed
            state.sources[index].updated = Date()
            state.sources[index].error = nil
        } else { state.sources.append(Source(url: url, feed: feed)) }
        save()
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for source in state.sources {
            guard let url = source.url else { continue }
            do {
                let feed = try await fetch(url)
                guard let index = state.sources.firstIndex(where: { $0.id == source.id }) else { continue }
                state.sources[index].feed = feed
                state.sources[index].updated = Date()
                state.sources[index].error = nil
            } catch {
                if let index = state.sources.firstIndex(where: { $0.id == source.id }) {
                    state.sources[index].error = error.localizedDescription
                }
            }
        }
        save()
    }
}

@main struct ShortDramaApp: App {
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup { Home().environmentObject(library).tint(.orange) }
    }
}
struct Home: View {
    @EnvironmentObject var library: Library
    var body: some View {
        TabView {
            Catalog(favoritesOnly: false).tabItem { Label("发现", systemImage: "play.rectangle") }
            Catalog(favoritesOnly: true).tabItem { Label("追剧", systemImage: "heart") }
            SourcesView().tabItem { Label("视频源", systemImage: "externaldrive") }
        }
        .alert("提示", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("好") { library.message = nil }
        } message: { Text(library.message ?? "") }
    }
}
struct Catalog: View {
    @EnvironmentObject var library: Library
    var favoritesOnly: Bool
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if library.state.sources.isEmpty {
                    ContentUnavailableView("添加你的视频源", systemImage: "play.rectangle", description: Text("在视频源页导入 HTTPS 源链接或 JSON 文件，开始看剧。"))
                }
                ForEach(library.state.sources) { source in
                    Section(source.feed.name) {
                        ForEach(source.feed.dramas.filter {
                            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) &&
                            (!favoritesOnly || library.state.favorites.contains(library.key(source, $0)))
                        }) { drama in
                            NavigationLink {
                                DramaView(sourceID: source.id, dramaID: drama.id)
                            } label: {
                                HStack(spacing: 14) {
                                    AsyncImage(url: drama.poster) { image in image.resizable().scaledToFill() }
                                    placeholder: { Rectangle().fill(.orange.opacity(0.15)).overlay(Image(systemName: "film")) }
                                        .frame(width: 64, height: 88).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(drama.title).font(.headline)
                                        Text("更新至 \(drama.episodes.count) 集").font(.caption).foregroundStyle(.secondary)
                                        if let last = library.state.watched[library.key(source, drama)],
                                           let index = drama.episodes.firstIndex(where: { $0.id == last }) {
                                            Text("上次观看第 \(index + 1) 集 · 剩余 \(drama.episodes.count - index - 1) 集").font(.caption2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(favoritesOnly ? "我的追剧" : "看短剧")
            .searchable(text: $search, prompt: "搜索已导入的剧集")
            .refreshable { await library.refresh() }
            .toolbar { if library.busy { ProgressView() } }
        }
    }
}
struct DramaView: View {
    @EnvironmentObject var library: Library
    let sourceID: UUID
    let dramaID: String
    @State private var selected: Episode?
    var body: some View {
        Group {
            if let source = library.state.sources.first(where: { $0.id == sourceID }),
               let drama = source.feed.dramas.first(where: { $0.id == dramaID }) {
                List {
                    Section {
                        Text(drama.summary ?? "暂无简介").foregroundStyle(.secondary)
                        Button(library.state.favorites.contains(library.key(source, drama)) ? "取消追剧" : "加入追剧") {
                            let key = library.key(source, drama)
                            if library.state.favorites.contains(key) { library.state.favorites.remove(key) }
                            else { library.state.favorites.insert(key) }
                            library.save()
                        }
                    }
                    Section("选集 · \(drama.episodes.count) 集") {
                        ForEach(drama.episodes) { episode in
                            Button { selected = episode; library.state.watched[library.key(source, drama)] = episode.id; library.save() }
                            label: { Label(episode.title, systemImage: "play.circle") }
                        }
                    }
                }.navigationTitle(drama.title)
            } else { ContentUnavailableView("剧集已移除", systemImage: "film") }
        }
        .sheet(item: $selected) { episode in PlayerScreen(episode: episode) }
    }
}
struct PlayerScreen: View {
    let episode: Episode
    @State private var player = AVPlayer()
    @State private var failure = false
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player).navigationTitle(episode.title).navigationBarTitleDisplayMode(.inline)
                .overlay(alignment: .bottom) {
                    if failure { Text("播放失败，请刷新视频源后重试。地址可能已过期或格式不支持。").padding().background(.regularMaterial) }
                }
                .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: episode.url)); player.play() }
                .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
                    if let item = notification.object as? AVPlayerItem, item === player.currentItem { failure = true }
                }
        }
    }
}
struct SourcesView: View {
    @EnvironmentObject var library: Library
    @State private var input = ""
    @State private var choosingFile = false
    var body: some View {
        NavigationStack {
            List {
                Section("导入视频源") {
                    TextField("HTTPS 源链接，或粘贴 JSON", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("导入") { Task { await library.importSource(text: input) } }.disabled(library.busy || input.isEmpty)
                    Button("从 JSON 文件导入") { choosingFile = true }.disabled(library.busy)
                }
                Section("已导入") {
                    ForEach(library.state.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.feed.name).font(.headline)
                            Text("\(source.feed.dramas.count) 部剧 · \(source.url == nil ? "本地快照" : "可刷新订阅")").font(.caption)
                            Text(source.updated, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let error = source.error { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }.onDelete { offsets in
                        let ids = offsets.map { library.state.sources[$0].id.uuidString + "/" }
                        library.state.sources.remove(atOffsets: offsets)
                        library.state.favorites = library.state.favorites.filter { key in !ids.contains(where: { key.hasPrefix($0) }) }
                        library.state.watched = library.state.watched.filter { key, _ in !ids.contains(where: { key.hasPrefix($0) }) }
                        library.save()
                    }.deleteDisabled(library.busy)
                    Button("更新全部订阅") { Task { await library.refresh() } }.disabled(library.busy)
                    if library.busy { ProgressView("正在获取视频源…") }
                }
                Section("关于") {
                    Text("无广告 SDK，无账号，无追踪。视频源需提供兼容 JSON；第三方视频可能包含内嵌广告。")
                    Text("红果：尚未完成适配，不作为可用视频源展示。")
                }
            }.navigationTitle("视频源")
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 5_000_000 else { throw FeedError.invalid("视频源超过 5 MB") }
                        library.add(try library.decode(Data(contentsOf: url)), url: nil)
                    } catch { library.message = error.localizedDescription }
                }
        }
    }
}
