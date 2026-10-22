#if DEBUG
import Foundation

@MainActor enum ShelfOrganizationCheck {
    static func run(directory: URL) throws {
        let store = ShelfOrganizationStore(directory: directory)
        store.change { try $0.addGroup("追更") }
        guard let group = store.value.groups.first else { throw SourceError.message("创建分组失败") }
        store.change { value in value.setMembership("book", group: group.id, enabled: true); value.pinned.insert("book") }
        let reloaded = ShelfOrganizationStore(directory: directory)
        guard reloaded.value == store.value, reloaded.matches("book", group: group.id), reloaded.value.pinned.contains("book") else { throw SourceError.message("分组或置顶重开后丢失") }
        try Data("bad-json".utf8).write(to: directory.appendingPathComponent("shelf-organization.json"), options: .atomic)
        let recovered = ShelfOrganizationStore(directory: directory)
        guard recovered.value.groups == [group], recovered.message != nil else { throw SourceError.message("损坏分组未从备份恢复") }
        recovered.change { try $0.renameGroup(group.id, name: "连载") }
        guard ShelfOrganizationStore(directory: directory).value.groups.first?.name == "连载" else { throw SourceError.message("分组恢复后不能保存") }
        let online = OnlineStore(directory: directory)
        var first = OnlineNovel(title: "分组书籍", url: URL(string: "https://group.example/one")!, sourceID: "first")
        first.shelfID = "stable-book"
        var replacement = first; replacement.sourceID = "second"
        guard ShelfOrganizationStore.key(first) == ShelfOrganizationStore.key(replacement) else { throw SourceError.message("换源改变了分组身份") }
        let second = OnlineNovel(title: "另一本", url: URL(string: "https://group.example/two")!, sourceID: "first")
        try online.keep(first); try online.keep(second)
        online.removeBooks([online.downloadKey(first)])
        guard OnlineStore(directory: directory).novels.map(\.id) == [second.id] else { throw SourceError.message("批量移出影响了未选中的在线书籍") }
    }
}
#endif
