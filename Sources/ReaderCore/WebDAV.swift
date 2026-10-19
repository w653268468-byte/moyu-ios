import Foundation

public struct WebDAVSnapshot: Sendable {
    public let data: Data
    public let etag: String?
    public init(data: Data, etag: String?) { self.data = data; self.etag = etag }
}

public enum SyncDecision: Equatable, Sendable {
    case unchanged, upload, download, conflict
    public static func compare(local: String, remote: String?, baseline: String?) -> SyncDecision {
        if remote == local { return .unchanged }
        guard let baseline else { return remote == nil ? .upload : .conflict }
        guard let remote else { return .conflict }
        if local == baseline { return .download }
        if remote == baseline { return .upload }
        return .conflict
    }
}

/// No redirects: a WebDAV endpoint must never forward credentials to another host.
private final class DAVRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor WebDAVClient {
    public static let maximumBytes = 400 * 1024 * 1024
    private let url: URL
    private let authorization: String
    private let session: URLSession
    public init(directory: String, username: String, password: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let base = URL(string: directory.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw SourceError.message("请填写 HTTPS WebDAV 文件夹地址，账号和密码填在各自的输入框中。")
        }
        url = base.appendingPathComponent("Gavin-sync.json")
        authorization = "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
        guard !username.contains(":"), !username.isEmpty else { throw SourceError.message("WebDAV 用户名不能为空或含冒号。") }
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config, delegate: DAVRedirectPolicy(), delegateQueue: nil)
    }
    private func request(_ method: String) -> URLRequest {
        var value = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        value.httpMethod = method; value.setValue(authorization, forHTTPHeaderField: "Authorization")
        value.setValue("Gavin/2.0", forHTTPHeaderField: "User-Agent")
        return value
    }
    public func read() async throws -> WebDAVSnapshot? {
        let (data, response) = try await send(request("GET"))
        if response.statusCode == 404 { return nil }
        try validate(response)
        return WebDAVSnapshot(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
    }
    public func write(_ data: Data, replacing snapshot: WebDAVSnapshot?) async throws {
        guard data.count <= Self.maximumBytes else { throw SourceError.message("同步备份超过大小限制。") }
        var value = request("PUT")
        value.httpBody = data; value.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let snapshot {
            guard let etag = snapshot.etag, etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\r"), !etag.contains("\n") else {
                throw SourceError.message("服务器未提供强 ETag，无法安全覆盖已有备份；请使用支持版本校验的 WebDAV 服务。")
            }
            value.setValue(etag, forHTTPHeaderField: "If-Match")
        } else { value.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await send(value)
        try validate(response)
    }
    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw SourceError.message("WebDAV 账号、密码或文件夹读写权限不正确。")
        case 409: throw SourceError.message("WebDAV 文件夹不存在，请先在服务端创建文件夹，再填写其地址。")
        case 412: throw SourceError.message("云端备份已被其他设备更新，本次没有覆盖，请重新同步并处理冲突。")
        case 300...399: throw SourceError.message("WebDAV 地址发生重定向，请填写服务提供的最终 HTTPS 文件夹地址。")
        default: throw SourceError.message("WebDAV 返回 HTTP \(response.statusCode)。")
        }
    }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SourceError.message("WebDAV 未返回 HTTP 响应。") }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw SourceError.message("云端备份超过大小限制。") }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw SourceError.message("云端备份超过大小限制。") }
            data.append(byte)
        }
        return (data, response)
    }
}
