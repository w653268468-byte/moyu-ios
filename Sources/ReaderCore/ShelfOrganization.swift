import Foundation

public struct ShelfGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(name: String) { id = UUID().uuidString; self.name = name }
}

public struct ShelfOrganization: Codable, Equatable, Sendable {
    public var groups: [ShelfGroup] = []
    public var memberships: [String: Set<String>] = [:]
    public var pinned: Set<String> = []
    public init() {}
    public func contains(_ key: String, in group: String) -> Bool {
        if group == "all" { return true }
        let assigned = (memberships[key] ?? []).intersection(groups.map(\.id))
        return group == "ungrouped" ? assigned.isEmpty : assigned.contains(group)
    }
    public mutating func addGroup(_ name: String) throws {
        guard groups.count < 100 else { throw SourceError.message("最多创建 100 个书架分组。") }
        groups.append(ShelfGroup(name: try validName(name)))
    }
    public mutating func renameGroup(_ id: String, name: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = try validName(name, excluding: id)
    }
    private func validName(_ raw: String, excluding id: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw SourceError.message("分组名称需为 1—40 个字符。") }
        guard !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw SourceError.message("已有同名分组。") }
        return name
    }
    public mutating func removeGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        for key in Array(memberships.keys) {
            memberships[key]?.remove(id)
            if memberships[key]?.isEmpty == true { memberships.removeValue(forKey: key) }
        }
    }
    public mutating func setMembership(_ key: String, group: String, enabled: Bool) {
        guard groups.contains(where: { $0.id == group }) else { return }
        if enabled { memberships[key, default: []].insert(group) }
        else { memberships[key]?.remove(group); if memberships[key]?.isEmpty == true { memberships.removeValue(forKey: key) } }
    }
}
