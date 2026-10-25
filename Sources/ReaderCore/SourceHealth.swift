import Foundation
import CryptoKit

private final class HealthSignatureCache: @unchecked Sendable {
    private final class Entry {
        let source: BookSource
        let signature: String
        init(_ source: BookSource, _ signature: String) { self.source = source; self.signature = signature }
    }
    static let shared = HealthSignatureCache()
    private let cache = NSCache<NSString, Entry>()
    private init() { cache.countLimit = 5000; cache.totalCostLimit = 32 * 1024 * 1024 }
    func value(_ source: BookSource, build: () -> (String, Int)) -> String {
        if let old = cache.object(forKey: source.id as NSString), old.source == source { return old.signature }
        let (signature, cost) = build(); cache.setObject(Entry(source, signature), forKey: source.id as NSString, cost: cost)
        return signature
    }
}

public enum SourceFailureKind: String, Codable, Sendable {
    case endpointGone, access, login, timeout, network, rule, other
    public static func classify(_ message: String) -> Self {
        let value = message.lowercased()
        if ["网站返回错误 http 404", "网站返回错误 http 410", "http 404", "http 410"].contains(where: value.hasPrefix) { return .endpointGone }
        if value.contains("http 403") || value.contains("http 429") || value.contains("访问限制") { return .access }
        if value.contains("超时") || value.contains("timed out") || value.contains("-1001") { return .timeout }
        if value.contains("网络") || value.contains("域名") || value.contains("证书") || value.contains("http 5") || value.contains("connection") { return .network }
        if value.contains("登录") || value.contains("需要验证") || value.contains("验证码") || value.contains("http 401") || value.contains("captcha") { return .login }
        if value.contains("规则") || value.contains("解析") || value.contains("javascript") || value.contains("json") { return .rule }
        return .other
    }
    public var name: String {
        switch self {
        case .endpointGone: return "接口地址失效"
        case .access: return "访问受限"
        case .login: return "需要登录或验证"
        case .timeout: return "响应超时"
        case .network: return "网络异常"
        case .rule: return "规则解析失败"
        case .other: return "检测未通过"
        }
    }
}

public struct SourceHealthRecord: Codable, Sendable {
    public var signature: String
    public var failures = 0
    public var confirmedGone = 0
    public var lastFailure: Date?
    public var lastSuccess: Date?
    public var lastValidated: Date?
    public var latency: Int?
    public var hasResults = false
    public var kind: SourceFailureKind?
    public var message = ""
    public var cooldownUntil: Date?
    public var removable: Bool { confirmedGone >= 2 && kind == .endpointGone }
}

public struct SourceHealthLedger: Codable, Sendable {
    public private(set) var records: [String: SourceHealthRecord] = [:]
    public init() {}
    public static func signature(_ source: BookSource) -> String {
        HealthSignatureCache.shared.value(source) {
        // Keep unknown rule fields, but a rename/group/enable change is not a new rule.
        let data = (try? SourceImport.export([source])) ?? Data()
        var object = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.first ?? [:]
        for key in ["bookSourceName", "bookSourceGroup", "enabled", "enabledExplore", "lastUpdateTime", "customOrder", "weight", "respondTime"] { object.removeValue(forKey: key) }
        let canonical = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? data
        return (SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(), canonical.count)
        }
    }
    public func record(for source: BookSource) -> SourceHealthRecord? {
        guard let record = records[source.id], record.signature == Self.signature(source) else { return nil }
        return record
    }
    public mutating func receive(_ source: BookSource, failure: String?, latency: Int? = nil, hasResults: Bool = false,
                                 verifiedProbe: Bool = false, fullValidation: Bool = false, now: Date = Date()) {
        var entry = record(for: source) ?? SourceHealthRecord(signature: Self.signature(source))
        if let failure {
            var kind = SourceFailureKind.classify(failure)
            if kind == .endpointGone {
                let raw = source.originalJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let login = (raw?["loginUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let header = (source.header ?? "").lowercased()
                if !login.isEmpty || header.contains("authorization") || header.contains("cookie") { kind = .login }
            }
            entry.failures += 1; entry.lastFailure = now; entry.kind = kind; entry.message = String(failure.prefix(1000))
            if verifiedProbe && kind == .endpointGone { entry.confirmedGone += 1 } else if kind != .endpointGone { entry.confirmedGone = 0 }
            if entry.failures >= 2 { entry.cooldownUntil = now.addingTimeInterval(kind == .login || kind == .access ? 900 : 300) }
        } else {
            entry.failures = 0; entry.confirmedGone = 0; entry.cooldownUntil = nil; entry.kind = nil; entry.message = ""
            entry.lastSuccess = now; entry.hasResults = hasResults || fullValidation || entry.hasResults
            if fullValidation { entry.lastValidated = now }
            if let latency { entry.latency = entry.latency.map { ($0 * 3 + latency) / 4 } ?? latency }
        }
        records[source.id] = entry
    }
    public mutating func reset(_ ids: Set<String>) { for id in ids { records.removeValue(forKey: id) } }
    public func ordered(_ sources: [BookSource], avoidingFailures: Bool = true, now: Date = Date()) -> (active: [BookSource], avoided: [BookSource]) {
        let cached = Dictionary(sources.map { ($0.id, record(for: $0)) }, uniquingKeysWith: { first, _ in first })
        func value(_ source: BookSource) -> SourceHealthRecord? { cached[source.id] ?? nil }
        func rank(_ source: BookSource) -> Int {
            guard let entry = value(source) else { return 2 }
            if entry.failures > 0 { return 4 }
            return (entry.lastValidated ?? .distantPast) > now.addingTimeInterval(-7 * 86400) ? 0 : entry.hasResults ? 1 : 3
        }
        let sorted = sources.enumerated().sorted { left, right in
            let a = rank(left.element), b = rank(right.element)
            if a != b { return a < b }
            let x = value(left.element)?.latency ?? Int.max, y = value(right.element)?.latency ?? Int.max
            return x == y ? left.offset < right.offset : x < y
        }.map(\.element)
        func avoid(_ source: BookSource) -> Bool { avoidingFailures && (value(source)?.removable == true || (value(source)?.cooldownUntil ?? .distantPast) > now) }
        return (sorted.filter { !avoid($0) }, sorted.filter(avoid))
    }
}
