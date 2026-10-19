import Foundation
import CryptoKit
import Security

/// Source-scoped, expiring script cache. Keys never become filesystem paths.
final class SourceScriptCache: @unchecked Sendable {
    static let shared = SourceScriptCache()
    private struct Entry: Codable { var value: String; var expires: Double }
    private let lock = NSLock()
    private let directory = URL.cachesDirectory.appendingPathComponent("GavinScriptCache", isDirectory: true)
    private func secretQuery(_ source: String, _ key: String) -> [String: Any]? {
        guard ["source:@loginInfo", "source:@loginHeader"].contains(key) else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.moyu.reader.source-login", kSecAttrAccount as String: file(source, key).lastPathComponent]
    }
    private func file(_ source: String, _ key: String) -> URL {
        let name = SHA256.hash(data: Data((source + "\u{0}" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    func get(_ source: String, _ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if var query = secretQuery(source, key) {
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let url = file(source, key)
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        guard entry.expires == 0 || entry.expires > Date().timeIntervalSince1970 else { try? FileManager.default.removeItem(at: url); return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry.value
    }
    func put(_ source: String, _ key: String, _ value: String, seconds: Double) throws {
        guard key.utf8.count <= 4096, value.utf8.count <= 2 * 1024 * 1024, seconds.isFinite, seconds >= 0 else { throw SourceError.message("脚本缓存键、内容或有效期超过限制。") }
        lock.lock(); defer { lock.unlock() }
        if let query = secretQuery(source, key) {
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query; attributes.forEach { insert[$0] = $1 }
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw SourceError.message("无法保存书源登录信息到钥匙串。") }
            } else if status != errSecSuccess { throw SourceError.message("无法更新书源登录信息。") }
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Entry(value: value, expires: seconds == 0 ? 0 : Date().timeIntervalSince1970 + seconds))
        let target = file(source, key)
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0 != target }.map { url in (url, try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = data.count + entries.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        var count = entries.count + 1
        for (url, values) in entries {
            if total <= 50 * 1024 * 1024 && count <= 5000 { break }
            try manager.removeItem(at: url); total -= values.fileSize ?? 0; count -= 1
        }
        try data.write(to: target, options: .atomic)
    }
    func delete(_ source: String, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        if let query = secretQuery(source, key) { SecItemDelete(query as CFDictionary) }
        else { try? FileManager.default.removeItem(at: file(source, key)) }
    }
}
