import SwiftUI

struct ShelfHeader: View {
    let localCount: Int
    let onlineCount: Int
    let updatedCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("我的书架").font(.system(size: 27, weight: .bold, design: .rounded))
                Spacer()
                Text("\(localCount + onlineCount) 本藏书").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                metric("在线藏书", value: onlineCount, symbol: "globe.asia.australia")
                Divider().frame(height: 27)
                metric("本地书籍", value: localCount, symbol: "books.vertical")
                Divider().frame(height: 27)
                metric("有新章节", value: updatedCount, symbol: "sparkles")
            }.padding(.vertical, 12).background(.background, in: RoundedRectangle(cornerRadius: 18))
        }.padding(.top, 10)
    }
    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        VStack(spacing: 5) {
            Label("\(value)", systemImage: symbol).font(.headline).foregroundStyle(.tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct NovelCover: View {
    let title: String
    var url: URL? = nil
    var compact = true
    private var color: Color {
        let palette: [Color] = [Color(red: 0.25, green: 0.40, blue: 0.36), Color(red: 0.43, green: 0.36, blue: 0.52), Color(red: 0.28, green: 0.39, blue: 0.53), Color(red: 0.56, green: 0.38, blue: 0.28)]
        return palette[title.utf8.reduce(0) { ($0 + Int($1)) % palette.count }]
    }
    var body: some View {
        ZStack {
            color.gradient
            Rectangle().fill(.black.opacity(0.10)).frame(width: compact ? 4 : 7).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, compact ? 3 : 6)
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "book.pages").font(compact ? .caption2 : .title2).opacity(0.7)
                Text(title).font(.system(size: compact ? 13 : 22, weight: .semibold, design: .serif)).lineLimit(compact ? 3 : 4)
                Spacer(minLength: 0)
                if !compact { Text("G A V I N").font(.system(size: 9, weight: .medium)).opacity(0.65) }
            }.foregroundStyle(.white).padding(compact ? 10 : 20).frame(maxWidth: .infinity, alignment: .leading)
            if let url { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear } }
        }.clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
            .overlay(alignment: .trailing) { RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.14)).frame(width: 2).padding(.trailing, 3).padding(.vertical, 5) }
            .shadow(color: color.opacity(0.20), radius: compact ? 3 : 7, y: compact ? 2 : 4)
            .accessibilityHidden(true)
    }
}

struct ShelfRefreshStatus: View {
    @EnvironmentObject private var online: OnlineStore
    @State private var showFailures = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if online.refreshingShelf { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 5) {
                Text(online.refreshStatus.isEmpty ? "下拉刷新，查看最新章节" : online.refreshStatus).font(.caption)
                    .foregroundStyle(.secondary).accessibilityIdentifier("shelf.refresh.status")
                if !online.refreshFailures.isEmpty {
                    Button("查看失败详情") { showFailures = true }.font(.caption).accessibilityIdentifier("shelf.refresh.failures")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if online.refreshingShelf { Button("停止") { online.cancelShelfRefresh() }.font(.caption).accessibilityIdentifier("shelf.refresh.cancel") }
            else { Button("刷新") { Task { await online.refreshShelf() } }.font(.caption.weight(.semibold)).accessibilityIdentifier("shelf.refresh") }
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
            .sheet(isPresented: $showFailures) {
                NavigationStack {
                    List(online.refreshFailures.keys.sorted(), id: \.self) { key in Text(online.refreshFailures[key] ?? "").textSelection(.enabled) }
                        .navigationTitle("更新失败详情").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFailures = false } } }
                }
            }
    }
}
