import Foundation
import SwiftSoup

struct RuleDocument {
    enum Node { case html(Element), json(Any) }
    let node: Node
    let scope: RuleScope

    static func parse(_ data: Data, base: URL, source: BookSource? = nil, globals: [String: String] = [:], script: SourceScript? = nil) throws -> RuleDocument {
        let scope = RuleScope(baseURL: base, source: source, globals: globals, script: script)
        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return RuleDocument(node: .json(value), scope: scope) }
        return RuleDocument(node: .html(try SwiftSoup.parse(TextParser.decode(data), base.absoluteString)), scope: scope)
    }

    private func child(_ node: Node) -> RuleDocument { RuleDocument(node: node, scope: scope) }
    var scriptInput: Any {
        get throws {
            switch node {
            case .html(let element): return ["__gavinHTML": try element.outerHtml()]
            case .json(let value): return value
            }
        }
    }
    private var rawText: String {
        get throws {
            switch node {
            case .html(let element): return try element.outerHtml()
            case .json(let value):
                if let string = value as? String { return string }
                return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
            }
        }
    }
    private func scripted(_ parts: ScriptRule.Parts, list: Bool, body: Bool = false) throws -> Any {
        let input: Any
        if parts.prefix.isEmpty { input = try rawText }
        else {
            switch node {
            case .html:
                if list { input = try elements(parts.prefix).map { try $0.scriptInput } }
                else { input = try value(parts.prefix, body: body) }
            case .json(let value):
                let nodes = try JSONPath.select(parts.prefix, from: value)
                let selected: Any = try JSONPath.isPlural(parts.prefix) ? nodes : (nodes.count == 1 ? nodes[0] : nodes)
                input = try (selected as? String) ?? String(decoding: JSONSerialization.data(withJSONObject: selected, options: .fragmentsAllowed), as: UTF8.self)
            }
        }
        return try scope.evaluate(parts.code, input: input, document: rawText)
    }
    func elements(_ rule: String) throws -> [RuleDocument] {
        try scope.enter(); defer { scope.leave() }
        let rule = try prepare(rule)
        for op in ["||", "&&", "%%"] {
            let parts = RuleComposition.split(rule, operator: op)
            if parts.count > 1 {
                var lists: [[RuleDocument]] = []
                for part in parts { let found = try elements(part); if op == "||" && !found.isEmpty { return found }; lists.append(found) }
                if op == "%%" { return (0..<(lists.map(\.count).max() ?? 0)).flatMap { index in lists.compactMap { $0.indices.contains(index) ? $0[index] : nil } } }
                return lists.flatMap { $0 }
            }
        }
        if let parts = try ScriptRule.parts(rule) {
            let result = try scripted(parts, list: true)
            return try ((result as? [Any]) ?? [result]).map { value in
                if let html = (value as? [String: Any])?["__gavinHTML"] as? String {
                    let parsed = try SwiftSoup.parse(html, scope.baseURL.absoluteString)
                    return child(.html(parsed.body()?.children().first() ?? parsed))
                }
                return child(.json(value))
            }
        }
        switch node {
        case .html(let element): return try HTMLRule.elements(rule, in: element).map { child(.html($0)) }
        case .json(let value): return try JSONRule.select(rule, from: value).map { child(.json($0)) }
        }
    }

    func value(_ rule: String?, body: Bool = false) throws -> String {
        guard let rawRule = rule, !rawRule.isEmpty else { return "" }
        try scope.enter(); defer { scope.leave() }
        let rule = try prepare(rawRule)
        if rule.isEmpty { return "" }
        for op in ["||", "&&", "%%"] {
            let parts = RuleComposition.split(rule, operator: op)
            if parts.count > 1 {
                var values: [String] = []
                for part in parts { let result = try value(part, body: body); if op == "||" && !result.isEmpty { return result }; values.append(result) }
                if op == "%%" {
                    let lists = values.map { $0.components(separatedBy: "\n") }
                    return (0..<(lists.map(\.count).max() ?? 0)).flatMap { index in lists.compactMap { $0.indices.contains(index) ? $0[index] : nil } }.joined(separator: "\n")
                }
                return values.filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
        if rule.contains("{{") {
            var parts = try RuleComposition.templates(rule), suffix = ""
            if let last = parts.last?.literal, let range = last.range(of: "##") {
                suffix = String(last[range.lowerBound...]); parts[parts.count - 1].literal = String(last[..<range.lowerBound])
            }
            var output = ""
            for part in parts {
                if let literal = part.literal { output += try interpolateVariables(literal) }
                if let expression = part.expression {
                    let code = expression.trimmingCharacters(in: .whitespacesAndNewlines)
                    if code.hasPrefix("@") || code.hasPrefix("$.") || code.hasPrefix("$[") || code.hasPrefix("//") { output += try value(code, body: body) }
                    else {
                        let result = try scope.evaluate(code, input: rawText, document: rawText)
                        if let string = result as? String { output += string } else if let number = result as? NSNumber { output += number.stringValue }
                    }
                }
                guard output.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("提取模板结果超过 8 MB。") }
            }
            return try RuleReplacement.apply(output, suffix: suffix)
        }
        if rule.hasPrefix("@get:{") && rule.hasSuffix("}") { return try scope.get(String(rule.dropFirst(6).dropLast())) }
        if rule.contains("@get:{"), rule.hasPrefix("https://") || rule.hasPrefix("http://") { return try interpolateVariables(rule) }
        if rule.hasPrefix("##") { return try RuleReplacement.apply(rawText, suffix: rule) }
        if let parts = try ScriptRule.parts(rule) {
            let result = try scripted(parts, list: false, body: body)
            if let html = (result as? [String: Any])?["__gavinHTML"] as? String { return try HTMLRule.value(body ? "text" : "html", in: SwiftSoup.parse(html), body: body) }
            if let text = result as? String { return text }
            if let number = result as? NSNumber { return number.stringValue }
            if result is NSNull { return "" }
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed), as: UTF8.self)
        }
        switch node {
        case .html(let element): return try HTMLRule.value(rule, in: element, body: body)
        case .json(let value):
            for alternate in JSONPath.alternatives(rule) {
                let parts = alternate.components(separatedBy: "##")
                var result = try JSONRule.select(parts[0], from: value).map { value -> String in
                    if value is NSNull { return "" }
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    return ""
                }.filter { !$0.isEmpty }.joined(separator: "\n")
                if parts.count > 1 { result = try RuleReplacement.apply(result, suffix: "##" + parts.dropFirst().joined(separator: "##")) }
                if !result.isEmpty { return result }
            }
            return ""
        }
    }

    func optionalValue(_ rule: String?) throws -> String {
        guard let rule, JSONRule.isSupported(rule) || HTMLRule.isSupported(rule) || ScriptRule.isSupported(rule) || RuleComposition.isSupported(rule) else { return "" }
        return try value(rule)
    }
    private func interpolateVariables(_ rule: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"@get:\{([^{}]+)\}"#)
        var result = rule
        for match in pattern.matches(in: rule, range: NSRange(rule.startIndex..., in: rule)).reversed() {
            guard let range = Range(match.range, in: result), let name = Range(match.range(at: 1), in: rule) else { continue }
            result.replaceSubrange(range, with: try scope.get(String(rule[name])))
        }
        return result
    }
    private func prepare(_ input: String) throws -> String {
        var rule = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while rule.hasPrefix("@put:") {
            guard let start = rule.firstIndex(of: "{") else { throw SourceError.message("@put 缺少变量对象。") }
            var depth = 0; var quote: Character?; var escaped = false; var end: String.Index?
            for index in rule.indices where index >= start {
                let char = rule[index]
                if let q = quote { if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == q { quote = nil } }
                else if char == "'" || char == "\"" { quote = char }
                else if char == "{" { depth += 1 }
                else if char == "}" { depth -= 1; if depth == 0 { end = index; break } }
            }
            guard let end else { throw SourceError.message("@put 变量对象未闭合。") }
            let contents = String(rule[rule.index(after: start)..<end])
            for entry in RuleComposition.split(contents, operator: ",") {
                guard let colon = entry.firstIndex(of: ":") else { throw SourceError.message("@put 变量缺少取值规则。") }
                let key = String(entry[..<colon]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                var extraction = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if extraction.hasPrefix("\""), let decoded = try? JSONSerialization.jsonObject(with: Data(extraction.utf8), options: .fragmentsAllowed) as? String { extraction = decoded }
                else if extraction.hasPrefix("'"), extraction.hasSuffix("'") { extraction = String(extraction.dropFirst().dropLast()) }
                try scope.put(key, value: value(extraction))
            }
            rule = String(rule[rule.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if rule.hasPrefix("@@") { rule = String(rule.dropFirst(2)) }
        if rule.lowercased().hasPrefix("@json:") { rule = String(rule.dropFirst(6)) }
        return rule
    }
}

public enum JSONRule {
    public static func isSupported(_ rule: String) -> Bool {
        JSONPath.alternatives(rule).allSatisfy { (try? JSONPath.compile($0.components(separatedBy: "##")[0])) != nil }
    }

    static func select(_ rule: String, from value: Any) throws -> [Any] {
        let nodes = try JSONPath.select(rule, from: value)
        // Preserve Legado's list extraction behavior for a single selected array.
        return nodes.count == 1 ? ((nodes[0] as? [Any]) ?? nodes) : nodes
    }
}
