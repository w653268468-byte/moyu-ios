import SwiftUI
import Security
import CryptoKit

private struct DAVAccount: Codable, Sendable {
    var directory: String
    var username: String
    var password: String
    var identity: String { SHA256.hash(data: Data((directory + "\n" + username).utf8)).map { String(format: "%02x", $0) }.joined() }
}

private actor DAVKeychain {
    static let shared = DAVKeychain()
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.moyu.reader.webdav", kSecAttrAccount as String: "primary"] }
    func load() throws -> DAVAccount? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SourceError.message("无法读取钥匙串中的 WebDAV 设置（\(status)）。") }
        return try JSONDecoder().decode(DAVAccount.self, from: data)
    }
    func save(_ account: DAVAccount) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw SourceError.message("无法保存 WebDAV 设置到钥匙串（\(status)）。") }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SourceError.message("无法删除 WebDAV 凭据（\(status)）。") }
    }
}

private enum SyncFingerprint {
    static func digest(_ data: Data) throws -> String {
        let backup = try JSONDecoder().decode(ReaderBackup.self, from: data)
        guard backup.version == 1, backup.files.count <= 25000,
              backup.files.values.reduce(0, { $0 + $1.count }) <= BackupService.maximumBytes else { throw SourceError.message("云端备份格式或大小不受支持。") }
        let preferences = try PropertyListSerialization.propertyList(from: backup.preferences, format: nil)
        // Exclude export time and canonicalize dictionary order so an unchanged backup compares equal.
        let object: [String: Any] = ["files": backup.files.mapValues { $0.base64EncodedString() }, "preferences": preferences]
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

struct WebDAVSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var online: OnlineStore
    @State private var directory = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saved: DAVAccount?
    @State private var busy = false
    @State private var message: String?
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    @State private var pending: PendingSync?
    @State private var confirm: SyncAction?
    private struct PendingSync {
        var local: Data
        var localDigest: String
        var remote: WebDAVSnapshot?
        var remoteDigest: String?
        var decision: SyncDecision
    }
    private enum SyncAction: String, Identifiable { case upload, download; var id: String { rawValue } }
    var body: some View {
        Form {
            Section("服务器") {
                TextField("HTTPS WebDAV 文件夹地址", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码 / WebDAV 授权密码", text: $password)
                Button("保存连接设置") { save() }.disabled(busy)
                Text("填写已存在的文件夹地址。Gavin 使用其中的 Gavin-sync.json；账号和密码仅保存在本机钥匙串，不进入备份。").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
            Section("同步书架、书籍与阅读设置") {
                Button("检查并同步", systemImage: "arrow.triangle.2.circlepath") { inspect() }.disabled(busy || saved == nil)
                if busy { ProgressView(status); Button("取消") { task?.cancel() } }
                if let pending {
                    Text(pending.decision == .conflict ? "本机与云端版本不同，请选择要保留的版本。" : "检查完成，请确认同步方向。")
                    Text("本机 \(pending.local.count / 1024) KB · 云端 \((pending.remote?.data.count ?? 0) / 1024) KB").font(.caption).foregroundStyle(.secondary)
                    if let remote = pending.remote, let backup = try? JSONDecoder().decode(ReaderBackup.self, from: remote.data) {
                        LabeledContent("云端备份时间", value: backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("保留本机并上传") { confirm = .upload }.disabled(busy)
                    if pending.remote != nil { Button("使用云端并恢复到本机") { confirm = .download }.disabled(busy) }
                }
                Text("同步采用完整快照，不自动合并两个不同版本。两台设备都修改过时由你选择。下载替换前，会在“文件 → Gavin → Gavin-Sync-Recovery”保留本机备份；恢复前请退出阅读页面。").font(.caption).foregroundStyle(.secondary)
            }
            Section { Button("移除本机连接设置", role: .destructive) { remove() }.disabled(busy || saved == nil) }
        }.navigationTitle("WebDAV 同步").navigationBarTitleDisplayMode(.inline)
            .task {
                do { if let account = try await DAVKeychain.shared.load() { saved = account; directory = account.directory; username = account.username; password = account.password } }
                catch { message = error.localizedDescription }
            }
            .onDisappear { task?.cancel() }
            .confirmationDialog(confirm == .upload ? "用本机快照更新云端？" : "用云端快照替换本机？", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let action = confirm { Button(action == .upload ? "确认上传" : "备份本机后恢复云端", role: .destructive) { transfer(action) } }
            }
            .alert("WebDAV", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
    }
    private func save() {
        task?.cancel(); busy = true; pending = nil
        let account = DAVAccount(directory: directory.trimmingCharacters(in: .whitespacesAndNewlines), username: username, password: password)
        task = Task {
            defer { busy = false }
            do {
                _ = try WebDAVClient(directory: account.directory, username: account.username, password: account.password)
                try await DAVKeychain.shared.save(account); saved = account; message = "已保存，点击“检查并同步”验证连接。"
            } catch { message = error.localizedDescription }
        }
    }
    private func remove() {
        busy = true
        task = Task {
            defer { busy = false }
            do {
                try await DAVKeychain.shared.remove()
                saved = nil; password = ""; pending = nil; message = "本机连接设置已移除，云端备份保留。"
            } catch { message = error.localizedDescription }
        }
    }
    private func inspect() {
        guard let account = saved else { return }
        busy = true; pending = nil; status = "正在比较本机与云端备份…"
        task = Task {
            defer { busy = false }
            do {
                let local = try BackupService.create(), digest = try SyncFingerprint.digest(local)
                let client = try WebDAVClient(directory: account.directory, username: account.username, password: account.password)
                let remote = try await client.read()
                let remoteDigest = try remote.map { try SyncFingerprint.digest($0.data) }
                try Task.checkCancellation()
                let decision = SyncDecision.compare(local: digest, remote: remoteDigest, baseline: UserDefaults.standard.string(forKey: "webdav.baseline." + account.identity))
                if decision == .unchanged { UserDefaults.standard.set(digest, forKey: "webdav.baseline." + account.identity); message = "本机和云端内容一致。" }
                else { pending = PendingSync(local: local, localDigest: digest, remote: remote, remoteDigest: remoteDigest, decision: decision) }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func transfer(_ action: SyncAction) {
        guard let account = saved, let snapshot = pending else { return }
        confirm = nil; busy = true; status = action == .upload ? "正在上传完整快照…" : "正在备份本机并恢复云端…"
        task = Task {
            defer { busy = false }
            do {
                guard try SyncFingerprint.digest(BackupService.create()) == snapshot.localDigest else { pending = nil; throw SourceError.message("检查后本机内容已变化，请重新检查同步，避免覆盖新进度。") }
                let client = try WebDAVClient(directory: account.directory, username: account.username, password: account.password)
                if action == .upload {
                    try await client.write(snapshot.local, replacing: snapshot.remote)
                    UserDefaults.standard.set(snapshot.localDigest, forKey: "webdav.baseline." + account.identity)
                    message = "已上传，其他设备可检查同步并恢复这份快照。"
                } else {
                    guard let remote = snapshot.remote else { return }
                    // Refetch so a pending choice cannot silently restore an outdated cloud version.
                    let latest = try await client.read()
                    guard latest?.data == remote.data else { pending = nil; throw SourceError.message("云端内容又有更新，请重新检查同步。") }
                    try Task.checkCancellation()
                    guard try SyncFingerprint.digest(BackupService.create()) == snapshot.localDigest else { pending = nil; throw SourceError.message("本机内容已变化，请重新检查同步。") }
                    let recovery = URL.documentsDirectory.appendingPathComponent("Gavin-Sync-Recovery", isDirectory: true)
                    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                    try snapshot.local.write(to: recovery.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
                    try BackupService.restore(remote.data)
                    library.reload(); online.reload()
                    UserDefaults.standard.set(snapshot.remoteDigest, forKey: "webdav.baseline." + account.identity)
                    message = "已恢复云端快照，本机旧快照已保留在文件中。"
                }
                pending = nil
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
