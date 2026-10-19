import Foundation

enum ScriptRule {
    struct Parts { let prefix: String; let code: String; let suffix: String }
    static func parts(_ rule: String) throws -> Parts? {
        let js = rule.range(of: "@js:", options: .caseInsensitive)
        let tag = rule.range(of: "<js>", options: .caseInsensitive)
        let ranges = [js, tag].compactMap { $0 }.sorted { $0.lowerBound < $1.lowerBound }
        guard let first = ranges.first else { return nil }
        var code = String(rule[first.upperBound...])
        var suffix = ""
        if first == tag {
            if let close = code.range(of: "</js>", options: .caseInsensitive) {
                suffix = String(code[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                code = String(code[..<close.lowerBound])
            }
        }
        return Parts(prefix: String(rule[..<first.lowerBound]), code: code, suffix: suffix)
    }
    static func isSupported(_ rule: String, depth: Int = 0) -> Bool {
        guard depth < 32, rule.utf8.count <= 512 * 1024 else { return false }
        guard let parts = try? parts(rule), !parts.code.isEmpty else { return false }
        return (parts.prefix.isEmpty || HTMLRule.isSupported(parts.prefix) || JSONRule.isSupported(parts.prefix) || RuleComposition.isSupported(parts.prefix)) &&
            (parts.suffix.isEmpty || HTMLRule.isSupported(parts.suffix) || JSONRule.isSupported(parts.suffix) || ScriptRule.isSupported(parts.suffix, depth: depth + 1) || RuleComposition.isSupported(parts.suffix))
    }
}

final class RuleScope {
    let baseURL: URL
    let source: BookSource?
    let globals: [String: String]
    private var script: SourceScript?
    private var depth = 0
    init(baseURL: URL, source: BookSource?, globals: [String: String] = [:], script: SourceScript? = nil) { self.baseURL = baseURL; self.source = source; self.globals = globals; self.script = script }
    func enter() throws { guard depth < 32 else { throw SourceError.message("规则嵌套超过 32 层。") }; depth += 1 }
    func leave() { depth = max(0, depth - 1) }
    private func engine() throws -> SourceScript {
        if script == nil {
            let value = try SourceScript()
            if let source {
                let json = try source.originalJSON ?? String(decoding: JSONEncoder().encode(source), as: UTF8.self)
                try value.setJSONGlobal("source", json: json)
            }
            script = value
        }
        return script!
    }
    func evaluate(_ code: String, input: Any, document: String) throws -> Any { try engine().evaluate(code, result: input, baseURL: baseURL, globals: globals, document: document) }
    func put(_ name: String, value: String) throws { try engine().putVariable(name, value: value) }
    func get(_ name: String) throws -> String { try engine().variable(name) }
}
