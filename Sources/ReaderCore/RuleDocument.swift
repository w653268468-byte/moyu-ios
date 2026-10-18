import Foundation
import SwiftSoup

enum RuleDocument {
    case html(Element)
    case json(Any)

    static func parse(_ data: Data, base: URL) throws -> RuleDocument {
        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return .json(value) }
        return .html(try SwiftSoup.parse(TextParser.decode(data), base.absoluteString))
    }

    func elements(_ rule: String) throws -> [RuleDocument] {
        switch self {
        case .html(let element): return try HTMLRule.elements(rule, in: element).map { .html($0) }
        case .json(let value): return try JSONRule.select(rule, from: value).map { .json($0) }
        }
    }

    func value(_ rule: String?, body: Bool = false) throws -> String {
        guard let rule, !rule.isEmpty else { return "" }
        switch self {
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
        guard let rule, JSONRule.isSupported(rule) || HTMLRule.isSupported(rule) else { return "" }
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
