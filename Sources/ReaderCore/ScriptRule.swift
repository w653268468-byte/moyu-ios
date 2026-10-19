import Foundation

enum ScriptRule {
    struct Parts { let prefix: String; let code: String; let suffix: String }
    static func parts(_ rule: String) throws -> Parts? {
        let chars = Array(rule)
        var quote: Character?, escaped = false, depth = 0
        var marker: (offset: Int, tag: Bool)?
        for index in chars.indices {
            let char = chars[index]
            if let current = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == current { quote = nil }
                continue
            }
            if char == "'" || char == "\"" || char == "`" { quote = char; continue }
            if depth == 0, index + 4 <= chars.count {
                let token = String(chars[index..<(index + 4)]).lowercased()
                if token == "@js:" || token == "<js>" { marker = (index, token == "<js>"); break }
            }
            if "([{".contains(char) { depth += 1 }
            else if ")] }".replacingOccurrences(of: " ", with: "").contains(char) { depth = max(0, depth - 1) }
        }
        guard let marker else { return nil }
        let start = rule.index(rule.startIndex, offsetBy: marker.offset)
        let first = start..<rule.index(start, offsetBy: 4)
        var code = String(rule[first.upperBound...])
        var suffix = ""
        if marker.tag {
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
