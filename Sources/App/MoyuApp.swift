import SwiftUI

@main
struct MoyuApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var online = OnlineStore()
    @State private var selectedTab: Int = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--ui-tab"), arguments.indices.contains(flag + 1), let tab = Int(arguments[flag + 1]), (0...3).contains(tab) { return tab }
        #endif
        return 0
    }()
    @State private var showReaderPreferences = false
    @State private var showReadingPreview = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ShelfView().tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
                SourceHubView().tabItem { Label("找书", systemImage: "magnifyingglass") }.tag(1)
                SourceManagerView().tabItem { Label("书源", systemImage: "globe.asia.australia") }.tag(2)
                AppSettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
            }
                .environmentObject(library)
                .environmentObject(online)
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-preferences") { showReaderPreferences = true }
                    if ProcessInfo.processInfo.arguments.contains("--ui-reading") {
                        UserDefaults.standard.set(true, forKey: "reader.fullScreen")
                        showReadingPreview = true
                    }
                    #endif
                }
                .fullScreenCover(isPresented: $showReadingPreview) {
                    #if DEBUG
                    let sample = "第一章 春日\n" + String(repeating: "清晨的阳光透过树叶，洒在安静的小路上。他翻开手中的书，故事从这一刻开始。阅读让旅途有了另一种风景。\n", count: 100)
                    let document = try! TextParser.parse(sample)
                    NavigationStack { ReaderView(book: Book(title: "Gavin 分页预览", document: document), document: document) }.environmentObject(library)
                    #endif
                }
                .sheet(isPresented: $showReaderPreferences) { NavigationStack { ReadingPreferences() } }
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
