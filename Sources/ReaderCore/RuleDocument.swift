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
                let selected: Any = nodes.count == 1 ? nodes[0] : nodes
                input = try (selected as? String) ?? String(decoding: JSONSerialization.data(withJSONObject: selected, options: .fragmentsAllowed), as: UTF8.self)
            }
        }
        return try scope.evaluate(parts.code, input: input, document: rawText)
    }
    func elements(_ rule: String) throws -> [RuleDocument] {
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
        guard let rule, !rule.isEmpty else { return "" }
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
                if parts.count > 1, !parts[1].isEmpty {
                    let regex = try NSRegularExpression(pattern: parts[1])
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: parts.count > 2 ? parts[2] : "")
                }
                if !result.isEmpty { return result }
            }
            return ""
        }
    }

    func optionalValue(_ rule: String?) throws -> String {
        guard let rule, JSONRule.isSupported(rule) || HTMLRule.isSupported(rule) || ScriptRule.isSupported(rule) else { return "" }
        return try value(rule)
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
