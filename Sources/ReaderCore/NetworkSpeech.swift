import Foundation
import CryptoKit

public struct NetworkSpeechEngine: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var url: String
    public var header: String?
    public var jsLib: String?
    public var loginUi: String?
    public var contentType: String?
    public var concurrentRate: String?
    public var pauseDuration: Int
    public var originalJSON: String
    public init(id: Int64, name: String, url: String, header: String? = nil, jsLib: String? = nil, loginUi: String? = nil,
                contentType: String? = nil, concurrentRate: String? = nil, pauseDuration: Int = 0, originalJSON: String = "{}") {
        self.id = id; self.name = name; self.url = url; self.header = header; self.jsLib = jsLib; self.loginUi = loginUi
        self.contentType = contentType; self.concurrentRate = concurrentRate; self.pauseDuration = min(10000, max(0, pauseDuration)); self.originalJSON = originalJSON
    }
    public var base: URL {
        let raw = url.components(separatedBy: ",{")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = URL(string: raw), ["http", "https"].contains(value.scheme?.lowercased() ?? ""), value.host != nil { return value }
        return URL(string: "https://tts.invalid/")!
    }
    public var minimumInterval: Double {
        let parts = (concurrentRate ?? "").split(separator: "/")
        guard parts.count == 2, let count = Double(parts[0]), let milliseconds = Double(parts[1]), count > 0, milliseconds > 0 else { return 0 }
        return min(10, milliseconds / count / 1000)
    }
}

public struct NetworkVoiceImport: Sendable {
    public var engines: [NetworkSpeechEngine]
    public var failures: [String]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 5 * 1024 * 1024 else { throw SourceError.message("音色配置超过 5 MB。") }
        let root = try JSONSerialization.jsonObject(with: data)
        let rows: [Any]
        if let list = root as? [Any] { rows = list }
        else if let object = root as? [String: Any] {
            rows = (object["httpTTS"] as? [Any]) ?? (object["data"] as? [Any]) ?? [object]
        } else { throw SourceError.message("请导入网络朗读 JSON 对象或数组。") }
        guard rows.count <= 500 else { throw SourceError.message("一次最多导入 500 个音色配置。") }
        var result = Self(engines: [], failures: [])
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any], let name = object["name"] as? String, !name.isEmpty, name.count <= 200,
                  let url = object["url"] as? String, !url.isEmpty, url.utf8.count <= 512 * 1024 else { result.failures.append("第 \(index + 1) 项缺少有效名称或接口"); continue }
            func field(_ key: String) -> String? {
                if let value = object[key] as? String { return value }
                if let value = object[key], JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) { return String(decoding: data, as: UTF8.self) }
                return nil
            }
            let hash = SHA256.hash(data: Data((name + "|" + url).utf8)).prefix(7).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            let id = (object["id"] as? NSNumber)?.int64Value ?? (object["id"] as? String).flatMap(Int64.init) ?? hash
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
            let engine = NetworkSpeechEngine(id: id, name: name, url: url, header: field("header"), jsLib: field("jsLib"), loginUi: field("loginUi"), contentType: field("contentType"), concurrentRate: field("concurrentRate") ?? (object["concurrentRate"] as? NSNumber)?.stringValue, pauseDuration: (object["pauseDuration"] as? NSNumber)?.intValue ?? 0, originalJSON: raw)
            if let old = result.engines.firstIndex(where: { $0.id == id }) { result.engines[old] = engine } else { result.engines.append(engine) }
        }
        guard !result.engines.isEmpty else { throw SourceError.message(result.failures.first ?? "没有音色配置。") }
        return result
    }
    public static func export(_ engines: [NetworkSpeechEngine]) throws -> Data {
        let rows = try engines.map { engine -> [String: Any] in
            var object = (try? JSONSerialization.jsonObject(with: Data(engine.originalJSON.utf8))) as? [String: Any] ?? [:]
            object["id"] = engine.id; object["name"] = engine.name; object["url"] = engine.url; object["pauseDuration"] = engine.pauseDuration
            for (key, value) in [("header", engine.header), ("jsLib", engine.jsLib), ("loginUi", engine.loginUi), ("contentType", engine.contentType), ("concurrentRate", engine.concurrentRate)] {
                if let value { object[key] = value } else { object.removeValue(forKey: key) }
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
    }
}

public actor NetworkSpeechClient {
    private let session: URLSession
    private let configuration: URLSessionConfiguration
    private var engines: [Int64: (NetworkSpeechEngine, SourceScript)] = [:]
    private var nextRequest: [Int64: Date] = [:]
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        self.configuration = config; session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    private func script(_ engine: NetworkSpeechEngine) throws -> SourceScript {
        if let old = engines[engine.id], old.0 == engine { return old.1 }
        let value = try SourceScript(configuration: configuration)
        var source = (try? JSONSerialization.jsonObject(with: Data(engine.originalJSON.utf8))) as? [String: Any] ?? [:]
        source["bookSourceUrl"] = "httpTts:\(engine.id)"; source["id"] = engine.id; source["url"] = engine.url
        source["name"] = engine.name; source["header"] = engine.header ?? ""
        try value.setJSONGlobal("source", json: String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self))
        if let library = engine.jsLib, !library.isEmpty {
            guard library.utf8.count <= 512 * 1024 else { throw SourceError.message("音色脚本过大。") }
            if let urls = try? JSONDecoder().decode([String: String].self, from: Data(library.utf8)) {
                guard urls.count <= 8 else { throw SourceError.message("共享音色脚本最多 8 个。") }
                let deadline = Date().addingTimeInterval(30)
                for name in urls.keys.sorted() {
                    try Task.checkCancellation()
                    guard Date() < deadline, let raw = urls[name] else { throw SourceError.message("共享音色脚本加载超时。") }
                    let url = try SourceClient.resolve(raw, base: engine.base)
                    guard url.host != "tts.invalid" else { throw SourceError.message("共享音色脚本需要有效地址。") }
                    let literal = String(decoding: try JSONSerialization.data(withJSONObject: url.absoluteString, options: .fragmentsAllowed), as: UTF8.self)
                    guard let code = try value.evaluate("java.ajax(\(literal))", result: "", baseURL: engine.base) as? String, code.utf8.count <= 512 * 1024 else { throw SourceError.message("共享音色脚本为空或过大。") }
                    _ = try value.evaluate(code + "\n;void 0;", result: "", baseURL: engine.base, timeout: 3, persistentDefinitions: true)
                }
            } else { _ = try value.evaluate(library + "\n;void 0;", result: "", baseURL: engine.base, timeout: 3, persistentDefinitions: true) }
        }
        if engines.count >= 3 { engines.removeAll() }
        engines[engine.id] = (engine, value)
        return value
    }
    public func request(_ engine: NetworkSpeechEngine, text: String, speed: Int = 10) throws -> URLRequest {
        guard text.count <= 4000 else { throw SourceError.message("单段朗读文字过长。") }
        let value = try script(engine)
        try value.setJSONGlobal("speakText", json: String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self))
        try value.setJSONGlobal("speakSpeed", json: String(min(50, max(5, speed))))
        var request = try SourceRequest.make(engine.url, query: "", base: engine.base, script: value)
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.host != "tts.invalid", url.user == nil, url.password == nil,
              !SourceRequest.requiresWebView(request) else { throw SourceError.message("在线音色需要有效的 HTTP/HTTPS 音频接口。") }
        if let header = engine.header, !header.isEmpty {
            for (key, item) in try SourceHeaders.parse(ScriptTemplate.expand(header, using: value, query: "", base: engine.base)) where key.lowercased() != "host" { request.setValue(item, forHTTPHeaderField: key) }
        }
        request.timeoutInterval = 15
        return request
    }
    public func render(_ engine: NetworkSpeechEngine, text: String, speed: Int = 10) async throws -> Data {
        let now = Date(), slot = max(now, nextRequest[engine.id] ?? now)
        nextRequest[engine.id] = slot.addingTimeInterval(engine.minimumInterval)
        if slot > now { try await Task.sleep(for: .seconds(slot.timeIntervalSince(now))) }
        let request = try request(engine, text: text, speed: speed)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.message("在线音色返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，请检查接口或登录参数。")
        }
        guard response.expectedContentLength <= 10 * 1024 * 1024 else { throw SourceError.message("音频超过 10 MB。") }
        var data = Data(); data.reserveCapacity(min(1024 * 1024, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count >= 10 * 1024 * 1024 { throw SourceError.message("音频超过 10 MB。") }
            data.append(byte)
        }
        try Task.checkCancellation()
        try Self.validateAudio(data)
        return data
    }
    public static func validateAudio(_ data: Data) throws {
        guard data.count >= 12 else { throw SourceError.message("音色接口没有返回完整音频。") }
        let prefix = String(decoding: data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.hasPrefix("<"), !prefix.hasPrefix("{"), !prefix.hasPrefix("[") else { throw SourceError.message("音色接口返回网页或错误 JSON，未返回可播放音频。") }
        let riff = data.starts(with: Data("RIFF".utf8)) && data.dropFirst(8).starts(with: Data("WAVE".utf8))
        let head = Array(data.prefix(12))
        let mp3 = data.starts(with: Data("ID3".utf8)) || (head[0] == 0xff && head[1] & 0xe0 == 0xe0)
        let m4a = data.dropFirst(4).starts(with: Data("ftyp".utf8))
        guard riff || mp3 || m4a else { throw SourceError.message("音频格式无法识别，请使用 MP3、WAV、AAC 或 M4A 接口。") }
    }
    public func loginInfo(_ engine: NetworkSpeechEngine) throws -> String {
        let value = try script(engine)
        return (try value.evaluate("source.getLoginInfo() || '{}'", result: "", baseURL: engine.base) as? String) ?? "{}"
    }
    public func setLoginInfo(_ json: String, engine: NetworkSpeechEngine) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json.utf8.count <= 32 * 1024 else { throw SourceError.message("登录参数需为 JSON 对象，最大 32 KB。") }
        let value = try script(engine)
        try value.setJSONGlobal("__speechLogin", json: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        _ = try value.evaluate("source.putLoginInfo(__speechLogin); void 0", result: "", baseURL: engine.base)
    }
    public func fields(_ engine: NetworkSpeechEngine) throws -> String {
        guard let ui = engine.loginUi, !ui.isEmpty else { return "[]" }
        if ui.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { return ui }
        let value = try script(engine), code = ui.hasPrefix("@js:") ? String(ui.dropFirst(4)) : ui
        let result = try value.evaluate(code, result: "", baseURL: engine.base)
        if let text = result as? String { return text }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }
    public func importText(_ input: String) async throws -> NetworkVoiceImport {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: text), url.scheme?.lowercased() == "legado", let source = url.queryItems?.first(where: { ["src", "url"].contains($0.name) })?.value { text = source }
        if let expression = try? NSRegularExpression(pattern: #"^\[[^\]\r\n]*\]\((https?://[^)\s]+)\)$"#),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) { text = String(text[range]) }
        switch try SourceImportInput.detect(text) {
        case .json(let data): return try NetworkVoiceImport.parse(data)
        case .links(let urls):
            var result = NetworkVoiceImport(engines: [], failures: [])
            var received = 0
            for url in urls {
                try Task.checkCancellation()
                if received >= 20 * 1024 * 1024 { result.failures.append("音色配置总下载量达到 20 MB，已停止获取余下链接。"); break }
                do {
                    let normalized = try SourceSubscription.normalize(url)
                    let (bytes, response) = try await session.bytes(from: normalized)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= 5 * 1024 * 1024 else { throw SourceError.message("音色链接返回错误或文件过大。") }
                    var data = Data()
                    for try await byte in bytes { guard data.count < 5 * 1024 * 1024, received < 20 * 1024 * 1024 else { throw SourceError.message("音色文件或总下载量过大。") }; data.append(byte); received += 1 }
                    let parsed = try NetworkVoiceImport.parse(data)
                    var merged = result.engines
                    for engine in parsed.engines { merged.removeAll { $0.id == engine.id }; merged.append(engine) }
                    guard merged.count <= 500 else { throw SourceError.message("音色总数超过 500。") }
                    result.engines = merged
                    result.failures += parsed.failures
                } catch { if Task.isCancelled { throw CancellationError() }; result.failures.append("\(url.host ?? "音色链接")：\(error.localizedDescription)") }
            }
            guard !result.engines.isEmpty else { throw SourceError.message(result.failures.joined(separator: "\n")) }
            return result
        }
    }
}
