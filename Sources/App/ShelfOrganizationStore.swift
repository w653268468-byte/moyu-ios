import SwiftUI

@MainActor final class ShelfOrganizationStore: ObservableObject {
    @Published private(set) var value = ShelfOrganization()
    @Published private(set) var message: String?
    private var locked = false
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("shelf-organization.json") }
    private var backup: URL { directory.appendingPathComponent("shelf-organization.backup.json") }
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("MoyuOnline")) {
        self.directory = directory; reload()
    }
    func reload() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                do { value = try JSONDecoder().decode(ShelfOrganization.self, from: Data(contentsOf: file)) }
                catch { value = try JSONDecoder().decode(ShelfOrganization.self, from: Data(contentsOf: backup)); message = "书架分组已从备份恢复。" }
            } else { value = ShelfOrganization() }
            locked = false
        } catch { locked = true; message = "读取分组失败，已暂停写入以保留原文件。" }
    }
    func change(_ mutation: (inout ShelfOrganization) throws -> Void) {
        guard !locked else { message = "请重新打开书架后重试，原分组文件已保留。"; return }
        do {
            var next = value; try mutation(&next)
            let encoded = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Backup the last successfully decoded state, even if the primary was damaged.
            try JSONEncoder().encode(value).write(to: backup, options: .atomic)
            try encoded.write(to: file, options: .atomic)
            value = next; message = nil
        } catch { message = error.localizedDescription }
    }
    func matches(_ key: String, group: String) -> Bool { value.contains(key, in: group) }
    static func key(_ book: Book) -> String { "local:" + book.id.uuidString }
    static func key(_ book: OnlineNovel) -> String { "online:" + book.id }
}

struct ShelfAssignment: Identifiable {
    let id: String
    let title: String
}

struct ShelfAssignmentView: View {
    @ObservedObject var store: ShelfOrganizationStore
    let assignment: ShelfAssignment
    @Environment(\.dismiss) private var dismiss
    @State private var manageGroups = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(assignment.title).font(.headline)
                    Toggle("置顶这本书", isOn: Binding(get: { store.value.pinned.contains(assignment.id) }, set: { enabled in
                        store.change { value in if enabled { value.pinned.insert(assignment.id) } else { value.pinned.remove(assignment.id) } }
                    })).accessibilityIdentifier("shelf.pin")
                }
                Section("加入分组（可多选）") {
                    if store.value.groups.isEmpty { Text("先创建一个分组，例如“追更”或“已完结”。").foregroundStyle(.secondary) }
                    ForEach(store.value.groups) { group in
                        Toggle(group.name, isOn: Binding(get: { store.value.memberships[assignment.id]?.contains(group.id) == true }, set: { enabled in store.change { $0.setMembership(assignment.id, group: group.id, enabled: enabled) } }))
                    }
                    Button("管理分组", systemImage: "folder.badge.plus") { manageGroups = true }
                }
                if let message = store.message { Text(message).foregroundStyle(.red) }
            }.navigationTitle("分组与置顶").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $manageGroups) { ShelfGroupManager(store: store) }
        }
    }
}

struct ShelfGroupManager: View {
    @ObservedObject var store: ShelfOrganizationStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming: ShelfGroup?
    @State private var renamed = ""
    @State private var deleting: ShelfGroup?
    var body: some View {
        NavigationStack {
            Form {
                Section("新建分组") {
                    TextField("例如：追更、已完结", text: $name).accessibilityIdentifier("shelf.group.name")
                    Button("创建分组") { store.change { try $0.addGroup(name) }; if store.message == nil { name = "" } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("shelf.group.create")
                }
                Section("已有分组") {
                    ForEach(store.value.groups) { group in
                        HStack {
                            Label(group.name, systemImage: "folder")
                            Spacer()
                            Text("\(store.value.memberships.values.filter { $0.contains(group.id) }.count) 本").font(.caption).foregroundStyle(.secondary)
                        }.swipeActions {
                            Button("删除", role: .destructive) { deleting = group }
                            Button("重命名") { renamed = group.name; renaming = group }.tint(.blue)
                        }
                    }
                    Text("删除分组只移除分类，书籍与阅读进度保留。").font(.caption).foregroundStyle(.secondary)
                }
                if let message = store.message { Text(message).foregroundStyle(.red) }
            }.navigationTitle("书架分组").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .alert("重命名分组", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("名称", text: $renamed)
                    Button("取消", role: .cancel) { renaming = nil }
                    Button("保存") { if let group = renaming { store.change { try $0.renameGroup(group.id, name: renamed) } }; renaming = nil }
                }
                .confirmationDialog("删除分组？书籍将保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除分组", role: .destructive) { if let group = deleting { store.change { $0.removeGroup(group.id) } }; deleting = nil }
                }
        }
    }
}
