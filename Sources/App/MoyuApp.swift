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
                .tint(Color(red: 0.24, green: 0.40, blue: 0.34))
                .alert("墨屿提示", isPresented: Binding(
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
