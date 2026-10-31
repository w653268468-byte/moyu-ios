import SwiftUI

enum AppBuildIdentity {
    static var label: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发版"
        let commit = Bundle.main.object(forInfoDictionaryKey: "GavinBuildCommit") as? String
        return "版本 \(version) · 构建 \(build)" + (commit.map { " · " + String($0.prefix(7)) } ?? "")
    }
}

@main
struct MoyuApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.interfaceAppearance") private var interfaceAppearance = InterfaceAppearance.light.rawValue
    @StateObject private var library = LibraryStore()
    @StateObject private var online = MoyuApp.makeOnlineStore()
    @MainActor private static func makeOnlineStore() -> OnlineStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-source-health") { return OnlineStore(directory: URL.documentsDirectory.appendingPathComponent("UI-health-online")) }
        if ProcessInfo.processInfo.arguments.contains("--ui-discovery") { return OnlineStore(directory: URL.documentsDirectory.appendingPathComponent("UI-discovery-online")) }
        #endif
        return OnlineStore()
    }
    @State private var selectedTab: Int = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--ui-tab"), arguments.indices.contains(flag + 1), let tab = Int(arguments[flag + 1]), (0...4).contains(tab) { return tab }
        #endif
        return 0
    }()
    @State private var showReaderPreferences = false
    @State private var showReadingPreview = false
    @State private var showSourceImportPreview = false
    @State private var verificationCheckResult = "running"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ShelfView().tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
                DiscoveryView().tabItem { Label("发现", systemImage: "sparkles") }.tag(4)
                SourceHubView().tabItem { Label("找书", systemImage: "magnifyingglass") }.tag(1)
                SourceManagerView().tabItem { Label("书源", systemImage: "globe.asia.australia") }.tag(2)
                AppSettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
            }
                .overlay(alignment: .bottom) { SpeechMiniPlayer() }
                .overlay(alignment: .top) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-verification-check") {
                        Text(verificationCheckResult).accessibilityIdentifier("source.verification.result")
                    }
                    #endif
                }
                .environmentObject(library)
                .environmentObject(online)
                .preferredColorScheme((InterfaceAppearance(rawValue: interfaceAppearance) ?? .light).scheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { online.pauseAllDownloads() }
                    if phase != .active {
                        do { try library.flushProgress(); try online.flushProgress() }
                        catch { online.errorMessage = "保存进度失败：" + error.localizedDescription }
                    }
                }
                .onAppear {
                    _ = ReaderFontStore.shared
                    if !UserDefaults.standard.bool(forKey: "reader.lightAppearanceMigration") {
                        interfaceAppearance = InterfaceAppearance.light.rawValue
                        let oldPaper = UserDefaults.standard.string(forKey: "reader.paper") ?? "cream"
                        if Paper(rawValue: oldPaper)?.isDark == true { UserDefaults.standard.set("cream", forKey: "reader.paper") }
                        UserDefaults.standard.set(true, forKey: "reader.lightAppearanceMigration")
                    }
                    #if DEBUG
                    try? Data("onAppear".utf8).write(to: URL.documentsDirectory.appendingPathComponent("ui-startup.txt"), options: .atomic)
                    if ProcessInfo.processInfo.arguments.contains("--ui-discovery"), online.sources.isEmpty,
                       let source = try? DiscoveryCheck.fixtureSource() { try? online.addSources([source]) }
                    if ProcessInfo.processInfo.arguments.contains("--ui-scroll-check") {
                        Task { @MainActor in try? await Task.sleep(for: .milliseconds(700)); ScrollReadingView.checkPositionRecovery() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-curl-check") {
                        Task { @MainActor in try? await Task.sleep(for: .milliseconds(700)); CurlReadingView.checkTurning() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-cookie-check") {
                        Task { await BrowserSessions.checkCookieSharing(client: online.client) }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-verification-check") {
                        Task { verificationCheckResult = await SourceVerificationCheck.run() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-import-check") {
                        Task { await SourceImportCheck.run() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-font-check") { Task { await FontImportCheck.run() } }
                    if ProcessInfo.processInfo.arguments.contains("--ui-speech-check") { Task { await ReaderSpeech.checkContinuousPlayback() } }
                    if ProcessInfo.processInfo.arguments.contains("--ui-search-model-check") { Task { await SearchModelCheck.run() } }
                    if ProcessInfo.processInfo.arguments.contains("--ui-online-shelf") {
                        UserDefaults.standard.set("在线", forKey: "reader.shelfScope")
                        try? online.prepareOfflineShelfFixture()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-catalog-refresh") {
                        UserDefaults.standard.set("在线", forKey: "reader.shelfScope")
                        UserDefaults.standard.set(false, forKey: "reader.fullScreen")
                        try? online.prepareOfflineShelfFixture(refreshable: true)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-shelf-refresh") {
                        UserDefaults.standard.set("在线", forKey: "reader.shelfScope")
                        UserDefaults.standard.set(false, forKey: "reader.fullScreen")
                        try? online.prepareOfflineShelfFixture(refreshable: true)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-prefetch-reader") {
                        UserDefaults.standard.set("在线", forKey: "reader.shelfScope")
                        UserDefaults.standard.set(false, forKey: "reader.fullScreen")
                        try? online.prepareOfflineShelfFixture(prefetchable: true)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-source-health"), online.sources.isEmpty {
                        let sources = ["gone", "login"].map { kind in
                            ["bookSourceName": kind == "gone" ? "失效测试源" : "登录测试源", "bookSourceUrl": "http://127.0.0.1:18765/health-\(kind)", "searchUrl": "/health-\(kind)/search?key={{key}}", "ruleSearch": ["bookList": ".book", "name": "a@text", "bookUrl": "a@href"], "ruleToc": ["chapterList": "#list a", "chapterName": "text", "chapterUrl": "href"], "ruleContent": ["content": "#content@text"]] as [String: Any]
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: sources), let parsed = try? SourceImport.parse(data) { try? online.addSources(parsed.sources) }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-import-preview") || ProcessInfo.processInfo.arguments.contains("--ui-import-samples") { showSourceImportPreview = true }
                    if ProcessInfo.processInfo.arguments.contains("--ui-preferences") { showReaderPreferences = true }
                    if ProcessInfo.processInfo.arguments.contains("--ui-all-next") { UserDefaults.standard.set(ReadingTapMap.allNext.stored, forKey: "reader.tapMap") }
                    if ProcessInfo.processInfo.arguments.contains("--ui-reading") || ProcessInfo.processInfo.arguments.contains("--ui-scroll") || ProcessInfo.processInfo.arguments.contains("--ui-epub") {
                        UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--ui-curl") ? "curl" : "slide", forKey: "reader.pageAnimation")
                        UserDefaults.standard.set(!ProcessInfo.processInfo.arguments.contains("--ui-scroll"), forKey: "reader.paged")
                        UserDefaults.standard.set(true, forKey: "reader.fullScreen")
                        showReadingPreview = true
                    }
                    #endif
                }
                .fullScreenCover(isPresented: $showReadingPreview) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-epub"), let book = library.books.first(where: { $0.originalEPUB == true }) {
                        NavigationStack { EPUBReaderLoader(book: book) }.environmentObject(library)
                    } else {
                    let sample = ProcessInfo.processInfo.arguments.contains("--ui-transform-sample")
                        ? "第一章 规则验证\n" + String(repeating: "ORIGINAL reader text.\n", count: 100)
                        : "第一章 春日\n" + String(repeating: "清晨的阳光透过树叶，洒在安静的小路上。他翻开手中的书，故事从这一刻开始。阅读让旅途有了另一种风景。\n", count: 100)
                    let document = try! TextParser.parse(sample)
                    NavigationStack { ReaderView(book: Book(title: "Gavin 分页预览", document: document), document: document) }.environmentObject(library)
                    }
                    #endif
                }
                .sheet(isPresented: $showReaderPreferences) { NavigationStack { ReadingPreferences() } }
                .sheet(isPresented: $showSourceImportPreview) { SourceImportView().environmentObject(online) }
                .tint(Color(red: 0.24, green: 0.40, blue: 0.34))
                .alert("Gavin提示", isPresented: Binding(
                    get: { library.errorMessage != nil || online.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil; online.errorMessage = nil } }
                )) {
                    Button("知道了") { library.errorMessage = nil; online.errorMessage = nil }
                } message: {
                    Text([library.errorMessage, online.errorMessage].compactMap { $0 }.joined(separator: "\n"))
                }
        }
    }
}
