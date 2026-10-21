import SwiftUI

struct OfflineBookControls: View {
    @EnvironmentObject private var online: OnlineStore
    let book: OnlineNovel
    private var state: OfflineDownloadState? { online.downloadState(book) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state {
                ProgressView(value: state.fraction)
                Text("已下载 \(state.completed)/\(state.total) 章").font(.caption).monospacedDigit()
                if !state.message.isEmpty { Text(state.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if !state.failed.isEmpty { Text("失败章节：" + state.failed.prefix(5).joined(separator: "、")).font(.caption).foregroundStyle(.orange) }
            }
            if state?.phase == .downloading {
                Button("暂停下载", systemImage: "pause.circle") { online.pauseDownload(book) }
            } else {
                Button(state?.phase == .failed ? "重试未下载章节" : state?.phase == .completed ? "检查并补全下载" : "下载 / 继续下载", systemImage: "arrow.down.circle") { online.startDownload(book) }.disabled(book.chapters.isEmpty)
            }
        }.task(id: book.sourceID + book.id + String(book.chapters.count)) { await online.refreshDownload(book) }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("退出本页面后继续下载。进入后台会暂停，回到前台后可继续；已下载章节无需重新下载。").font(.caption).foregroundStyle(.secondary)
                }
                if online.novels.isEmpty {
                    ContentUnavailableView("还没有在线藏书", systemImage: "books.vertical", description: Text("在找书中搜索小说，获取目录后加入书架，即可离线下载。"))
                }
                ForEach(online.novels) { book in
                    Section(book.title) { OfflineBookControls(book: book) }
                }
            }.navigationTitle("离线下载").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
