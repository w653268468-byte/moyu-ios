import Foundation
import CryptoKit
import QuickJS
import SwiftSoup

/// An isolated, bounded interpreter. Android objects are implemented explicitly by the bridge.
public final class SourceScript: @unchecked Sendable {
    private final class Limit {
        let lock = NSLock()
        var deadline = ProcessInfo.processInfo.systemUptime + 10
        var absoluteDeadline = ProcessInfo.processInfo.systemUptime + 30
        var ioStart: Double?
        var cancelled = false
        func begin(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; deadline = ProcessInfo.processInfo.systemUptime + seconds; absoluteDeadline = ProcessInfo.processInfo.systemUptime + min(30, seconds + 20); ioStart = nil; cancelled = false }
        func beginIO() { lock.lock(); defer { lock.unlock() }; ioStart = ProcessInfo.processInfo.systemUptime }
        func endIO() { lock.lock(); defer { lock.unlock() }; if let start = ioStart { deadline += ProcessInfo.processInfo.systemUptime - start }; ioStart = nil }
        func stop() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        func exceeded() -> Bool { lock.lock(); defer { lock.unlock() }; let now = ProcessInfo.processInfo.systemUptime; return cancelled || now > absoluteDeadline || (ioStart == nil && now > deadline) }
    }
    private let limit: Limit
    private let gate = NSLock()
    private let runtime: JSRuntime
    private let context: JSContext
    private let http: ScriptHTTP
    private let configuration: URLSessionConfiguration
    private var input = ""
    private var base = URL(string: "https://example.com")!
    private var variables: [String: String] = [:]

    public init(configuration: URLSessionConfiguration = .ephemeral) throws {
        let limit = Limit()
        self.limit = limit
        self.configuration = configuration
        self.http = ScriptHTTP(configuration: configuration)
        guard let runtime = JSRuntime(options: JSRuntimeOptions(memoryLimit: 64 * 1024 * 1024, enableStdModules: false, enableHelpers: false, interruptHandler: { limit.exceeded() }, flushJobsAfterEval: false)),
              let context = runtime.createContext() else { throw SourceError.message("无法初始化 JavaScript 引擎。") }
        self.runtime = runtime; self.context = context
        let _: JSModule? = context.module("GavinNative") {
            JSModuleFunction("call", argc: 2) { [weak self] ctx, _, count, args in
                guard let self, count >= 2, let args, let method = String(ctx, value: args[0]), let payload = String(ctx, value: args[1]) else { return JSError.exception("Invalid bridge call") }
                do { return try self.native(method, payload: payload) }
                catch { return JSError.exception(error.localizedDescription) }
            }
        }
        try context.evaluate("import * as native from 'GavinNative'; globalThis.__native = native;", options: EvalOptions(type: .module))
        try context.evaluate(Self.bootstrap)
    }

    public func cancel() { limit.stop() }
    public func variable(_ name: String) -> String { gate.lock(); defer { gate.unlock() }; return variables[name] ?? "" }
    public func snapshotVariables() -> [String: String] { gate.lock(); defer { gate.unlock() }; return variables }
    public func restoreVariables(_ values: [String: String]) throws {
        gate.lock(); defer { gate.unlock() }
        guard values.count <= 1000, values.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 1024 * 1024 else { throw SourceError.message("书源变量超过限制。") }
        variables = values
    }
    func putVariable(_ name: String, value: String) throws {
        gate.lock(); defer { gate.unlock() }; try storeVariable(name, value: value)
    }
    private func storeVariable(_ name: String, value: String) throws {
        let total = variables.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) - (variables[name]?.utf8.count ?? 0)
        guard name.utf8.count <= 2048, value.utf8.count <= 256 * 1024,
              (variables[name] != nil || variables.count < 1000), total + value.utf8.count <= 1024 * 1024 else { throw SourceError.message("书源变量超过限制。") }
        variables[name] = value
    }

    public func setJSONGlobal(_ name: String, json: String) throws {
        gate.lock(); defer { gate.unlock() }
        limit.begin(2)
        context.setGlobalProperty(name: "__gavinGlobal", value: json)
        let value = try context.evaluate("JSON.parse(__gavinGlobal)")
        context.setGlobalProperty(name: name, value: value)
    }

    /// Returns JSON, including scalar strings, so arrays and objects survive extraction.
    public func evaluate(_ code: String, result: Any, baseURL: URL, globals: [String: String] = [:], timeout: Double = 2, document: String? = nil, persistentDefinitions: Bool = false) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
        guard code.utf8.count <= 512 * 1024, data.count <= 8 * 1024 * 1024 else { throw SourceError.message("脚本或输入超过大小限制。") }
        gate.lock(); defer { gate.unlock() }
        limit.begin(min(15, max(0.05, timeout)))
        input = document ?? (result as? String ?? String(decoding: data, as: UTF8.self)); base = baseURL
        context.setGlobalProperty(name: "__gavinInput", value: String(decoding: data, as: UTF8.self))
        context.setGlobalProperty(name: "baseUrl", value: baseURL.absoluteString)
        context.setGlobalProperty(name: "src", value: input)
        for (name, value) in globals {
            if name == "page", let page = Int(value) { context.setGlobalProperty(name: name, value: page) }
            else { context.setGlobalProperty(name: name, value: value) }
        }
        do {
            try context.evaluate("globalThis.result = JSON.parse(__gavinInput, (_, v) => v && typeof v.__gavinHTML === 'string' ? new GavinElement(v.__gavinHTML) : v)")
            // Rule-local let/const bindings must not collide on the next page or query.
            // Direct eval preserves the script completion value. Shared libraries opt in
            // to global definitions, while java.put/get remains explicitly persistent.
            context.setGlobalProperty(name: "__gavinCode", value: code)
            let value = try context.evaluate(persistentDefinitions ? code : "(function(){ return eval(__gavinCode); }).call(globalThis)")
            context.setGlobalProperty(name: "__gavinResult", value: value)
            guard let json = try context.evaluate("JSON.stringify(typeof __gavinResult === 'undefined' ? result : __gavinResult, (_, v) => v instanceof GavinElement ? {__gavinHTML: v.outerHtml()} : v)").string,
                  let data = json.data(using: .utf8), data.count <= 8 * 1024 * 1024 else { throw SourceError.message("JavaScript 未返回可提取的结果，或结果过大。") }
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            if limit.exceeded() { throw SourceError.message("JavaScript 执行已取消或超过时间限制。") }
            let detail = (error as? JSError)?.message ?? error.localizedDescription
            throw SourceError.message("JavaScript：\(detail.prefix(500))")
        }
    }

    private func native(_ method: String, payload: String) throws -> String {
        guard let data = payload.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw SourceError.message("脚本参数无效。") }
        func string(_ index: Int) -> String { args.indices.contains(index) ? (args[index] as? String ?? String(describing: args[index])) : "" }
        func content(_ index: Int) throws -> String {
            guard args.indices.contains(index), !(args[index] is NSNull) else { return input }
            if let html = (args[index] as? [String: Any])?["__gavinHTML"] as? String { return html }
            if args[index] is [String: Any] || args[index] is [Any] { return String(decoding: try JSONSerialization.data(withJSONObject: args[index]), as: UTF8.self) }
            return string(index)
        }
        func document(_ text: String) throws -> RuleDocument { try RuleDocument.parse(Data(text.utf8), base: base) }
        let result: Any
        if ["getString", "getStringList", "getElements", "getElement"].contains(method), try ScriptRule.parts(string(0)) != nil {
            throw SourceError.message("暂未实现 java.\(method) 内的嵌套脚本。")
        }
        switch method {
        case "getString", "getStringList":
            let value = try document(content(1)).value(string(0))
            let values = value.components(separatedBy: "\n").filter { !$0.isEmpty }
            let urls = args.count > 2 && (args[2] as? Bool == true)
            let extracted: [String]
            if urls { extracted = try values.map { try SourceClient.resolve($0, base: base).absoluteString } } else { extracted = values }
            result = method == "getString" ? (urls ? extracted.joined(separator: "\n") : value) as Any : extracted as Any
        case "setContent":
            input = try content(0)
            if args.count > 1, !(args[1] is NSNull), !string(1).isEmpty { base = try SourceClient.resolve(string(1), base: base) }
            result = NSNull()
        case "getElement":
            let first = try document(input).elements(string(0)).first
            if let first { switch first.node { case .html(let element): result = ["__gavinHTML": try element.outerHtml()]; case .json(let value): result = value } }
            else { result = NSNull() }
        case "getElements":
            result = try document(args.count > 1 ? string(1) : input).elements(string(0)).map { node -> Any in
                switch node.node {
                case .html(let element): return ["__gavinHTML": try element.outerHtml()]
                case .json(let value): return value
                }
            }
        case "css": result = try SwiftSoup.parse(string(1), base.absoluteString).select(string(0)).array().map { ["__gavinHTML": try $0.outerHtml()] }
        case "text": result = try SwiftSoup.parse(string(0), base.absoluteString).text()
        case "html": result = try SwiftSoup.parse(string(0), base.absoluteString).body()?.html() ?? ""
        case "attr": result = try SwiftSoup.parse(string(0), base.absoluteString).body()?.children().first()?.attr(string(1)) ?? ""
        case "put": try storeVariable(string(0), value: string(1)); result = string(1)
        case "get" where !(string(0).hasPrefix("https://") || string(0).hasPrefix("http://")): result = variables[string(0)] ?? ""
        case "ajax", "get", "post":
            var request = try SourceRequest.make(string(0), query: "", base: base)
            if method == "post" {
                request.httpMethod = "POST"
                request.httpBody = Data(string(1).utf8)
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
            let headerIndex = method == "post" ? 2 : 1
            if args.indices.contains(headerIndex), let headers = args[headerIndex] as? [String: String] {
                for (name, value) in headers where name.lowercased() != "host" { request.setValue(value, forHTTPHeaderField: name) }
            }
            limit.beginIO(); defer { limit.endIO() }
            let response = try http.request(request, cancelled: { self.limit.exceeded() })
            result = method == "ajax" ? response.text : response.json
        case "getCookie":
            let url = try SourceClient.resolve(string(0), base: base)
            result = HTTPCookie.requestHeaderFields(with: configuration.httpCookieStorage?.cookies(for: url) ?? [])["Cookie"] ?? ""
        case "setCookie":
            let url = try SourceClient.resolve(string(0), base: base)
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": string(1)], for: url) { configuration.httpCookieStorage?.setCookie(cookie) }
            result = NSNull()
        case "base64Encode": result = Data(string(0).utf8).base64EncodedString()
        case "base64Decode":
            guard let bytes = Data(base64Encoded: string(0), options: .ignoreUnknownCharacters), let text = String(data: bytes, encoding: .utf8) else { throw SourceError.message("Base64 文本无效或不是 UTF-8。") }
            result = text
        case "md5Encode": result = Insecure.MD5.hash(data: Data(string(0).utf8)).map { String(format: "%02x", $0) }.joined()
        case "sha256Encode": result = SHA256.hash(data: Data(string(0).utf8)).map { String(format: "%02x", $0) }.joined()
        case "hexEncodeToString": result = Data(string(0).utf8).map { String(format: "%02x", $0) }.joined()
        case "hexDecodeToString", "hexDecodeToByteArray":
            let value = Array(string(0).utf8)
            guard value.count.isMultiple(of: 2), value.count <= 2 * 1024 * 1024 else { throw SourceError.message("Hex 长度无效或超过限制。") }
            var bytes = [UInt8](); bytes.reserveCapacity(value.count / 2)
            for i in stride(from: 0, to: value.count, by: 2) {
                guard let byte = UInt8(String(decoding: value[i...i+1], as: UTF8.self), radix: 16) else { throw SourceError.message("Hex 包含无效字符。") }; bytes.append(byte)
            }
            if method == "hexDecodeToByteArray" { result = bytes.map { Int(Int8(bitPattern: $0)) } }
            else { guard let text = String(data: Data(bytes), encoding: .utf8) else { throw SourceError.message("Hex 结果不是 UTF-8 文本。") }; result = text }
        case "randomUUID": result = UUID().uuidString.lowercased()
        case "getWebViewUA": result = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
        case "t2s", "s2t":
            guard let text = string(0).applyingTransform(StringTransform("Traditional-Simplified"), reverse: method == "s2t") else { throw SourceError.message("当前系统无法进行繁简转换。") }; result = text
        case "timeFormat", "timeFormatUTC":
            guard let milliseconds = Double(string(0)), milliseconds.isFinite, abs(milliseconds) < 8.64e15 else { throw SourceError.message("时间戳无效，应为毫秒。") }
            let format = method == "timeFormatUTC" ? string(1) : "yyyy-MM-dd HH:mm:ss"
            guard !format.isEmpty, format.utf8.count <= 128 else { throw SourceError.message("时间格式为空或过长。") }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
            if method == "timeFormatUTC" {
                guard let hour = Int(string(2)), (-14...14).contains(hour), let zone = TimeZone(secondsFromGMT: hour * 3600) else { throw SourceError.message("时区偏移无效。") }; formatter.timeZone = zone
            }
            result = formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        case "resolve": result = try SourceClient.resolve(string(0), base: base).absoluteString
        case "log": result = NSNull()
        default: throw SourceError.message("尚未实现书源脚本接口 java.\(method)")
        }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: encoded, as: UTF8.self)
    }

    private static let bootstrap = #"""
    function gavinCall(name, args) {
        return JSON.parse(__native.call(name, JSON.stringify(args)), (_, v) => v && typeof v.__gavinHTML === 'string' ? new GavinElement(v.__gavinHTML) : v && v.__gavinResponse ? new GavinResponse(v.__gavinResponse) : v);
    }
    class GavinResponse {
        constructor(value) { this.value = value; }
        body() { return this.value.body; }
        url() { return this.value.url; }
        code() { return this.value.status; }
        headers() { return this.value.headers; }
        toString() { return this.body(); }
    }
    class GavinElement {
        constructor(html) { this.value = html; }
        toString() { return this.value; }
        outerHtml() { return this.value; }
        toJSON() { return {__gavinHTML: this.value}; }
        text() { return gavinCall('text', [this.value]); }
        html() { return gavinCall('html', [this.value]); }
        attr(name) { return gavinCall('attr', [this.value, String(name)]); }
        select(css) { return gavinCall('css', [String(css), this.value]); }
        getElementsByTag(tag) { return this.select(tag); }
        getElementsByClass(name) { return this.select('.' + name); }
        getElementById(name) { return this.select('#' + name).first(); }
    }
    Object.defineProperties(Array.prototype, {
        toArray: {value: function() { return this.slice(); }},
        get: {value: function(i) { return this[i]; }},
        size: {value: function() { return this.length; }},
        first: {value: function() { return this[0] ?? null; }},
        last: {value: function() { return this[this.length - 1] ?? null; }}
        ,text: {value: function() { return this.map(e => e instanceof GavinElement ? e.text() : String(e)).join(' '); }}
        ,html: {value: function() { return this.map(e => e instanceof GavinElement ? e.html() : String(e)).join('\n'); }}
        ,attr: {value: function(name) { return this[0] instanceof GavinElement ? this[0].attr(name) : ''; }}
        ,select: {value: function(css) { return this.flatMap(e => e instanceof GavinElement ? e.select(css) : []); }}
        ,isEmpty: {value: function() { return this.length === 0; }}
        ,eachText: {value: function() { return this.map(e => e instanceof GavinElement ? e.text() : String(e)); }}
    });
    globalThis.java = new Proxy({}, {get: (_, name) => (...args) => gavinCall(String(name), args)});
    globalThis.org = {jsoup: {Jsoup: {parse: html => new GavinElement(String(html))}}};
    globalThis.jsoup = org.jsoup.Jsoup;
    globalThis.source = {};
    globalThis.book = {};
    globalThis.chapter = {};
    globalThis.key = '';
    globalThis.page = 1;
    globalThis.console = {log: (...args) => java.log(args.join(' '))};
    """#
}
