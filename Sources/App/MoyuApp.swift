import SwiftUI

@main
struct MoyuApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var online = OnlineStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                ShelfView().tabItem { Label("书架", systemImage: "books.vertical") }
                SourceHubView().tabItem { Label("找书", systemImage: "magnifyingglass") }
                SourceManagerView().tabItem { Label("书源", systemImage: "globe.asia.australia") }
                AppSettingsView().tabItem { Label("设置", systemImage: "gearshape") }
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
