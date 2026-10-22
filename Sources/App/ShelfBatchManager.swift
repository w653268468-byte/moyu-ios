import SwiftUI

private struct ShelfBatchEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

struct ShelfBatchManager: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var online: OnlineStore
    @ObservedObject var organization: ShelfOrganizationStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var confirmDelete = false
    private var entries: [ShelfBatchEntry] {
        let all = library.books.map { ShelfBatchEntry(id: ShelfOrganizationStore.key($0), title: $0.title, subtitle: "本地 · \($0.chapterCount) 章") }
            + online.novels.map { ShelfBatchEntry(id: ShelfOrganizationStore.key($0), title: $0.title, subtitle: "在线 · \($0.author)") }
        return all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("已选 \(selected.count) 本").font(.headline)
                        Spacer()
                        Button("全选结果") { selected.formUnion(entries.map(\.id)) }
                        Button("清空") { selected = [] }
                    }.font(.caption)
                }
                Section {
                    ForEach(entries) { entry in
                        Button {
                            if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) { Text(entry.title).foregroundStyle(.primary); Text(entry.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }.frame(minHeight: 44)
                        }.accessibilityValue(selected.contains(entry.id) ? "已选择" : "未选择")
                    }
                }
                if let message = organization.message { Text(message).foregroundStyle(.red) }
            }.searchable(text: $query, prompt: "筛选要管理的书籍")
                .navigationTitle("批量管理").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 18) {
                        Menu("加入分组", systemImage: "folder") {
                            ForEach(organization.value.groups) { group in Button(group.name) { organization.change { value in for key in selected { value.setMembership(key, group: group.id, enabled: true) } } } }
                            Button("移出所有分组") { organization.change { value in for key in selected { value.memberships.removeValue(forKey: key) } } }
                        }
                        Menu("置顶", systemImage: "pin") {
                            Button("置顶所选") { organization.change { $0.pinned.formUnion(selected) } }
                            Button("取消置顶") { organization.change { $0.pinned.subtract(selected) } }
                        }
                        Spacer()
                        Button("删除", role: .destructive) { confirmDelete = true }
                    }.font(.subheadline).padding().background(.bar).disabled(selected.isEmpty)
                }
                .confirmationDialog("处理选中的 \(selected.count) 本书？本地书籍及文件会删除；在线书籍仅移出书架，章节缓存保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("确认删除与移出", role: .destructive) {
                        let localIDs = Set(library.books.filter { selected.contains(ShelfOrganizationStore.key($0)) }.map(\.id))
                        let onlineKeys = Set(online.novels.filter { selected.contains(ShelfOrganizationStore.key($0)) }.map { online.downloadKey($0) })
                        library.deleteBooks(localIDs); online.removeBooks(onlineKeys)
                        let remaining = Set(library.books.map { ShelfOrganizationStore.key($0) } + online.novels.map { ShelfOrganizationStore.key($0) })
                        let removed = selected.subtracting(remaining)
                        organization.change { value in for key in removed { value.memberships.removeValue(forKey: key); value.pinned.remove(key) } }
                        selected.formIntersection(remaining)
                    }
                }
        }
    }
}
