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
            for alternate in rule.components(separatedBy: "||") {
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
    private enum Token { case key(String), index(Int), wildcard }

    public static func isSupported(_ rule: String) -> Bool {
        rule.components(separatedBy: "||").allSatisfy { (try? tokens($0.components(separatedBy: "##")[0])) != nil }
    }

    private static func tokens(_ raw: String) throws -> [Token] {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("@json:") { path.removeFirst(6) }
        if path == "text" || path == "$" || path == "@" { return [] }
        if path.hasPrefix("$") { path.removeFirst() }
        var result: [Token] = []
        while !path.isEmpty {
            if path.hasPrefix(".") {
                path.removeFirst()
                guard !path.isEmpty, !path.hasPrefix(".") else { throw unsupported(raw) }
            }
            if path.hasPrefix("[") {
                guard let end = path.firstIndex(of: "]") else { throw unsupported(raw) }
                let item = String(path[path.index(after: path.startIndex)..<end])
                if item == "*" { result.append(.wildcard) }
                else if let index = Int(item) { result.append(.index(index)) }
                else if item.count >= 2, (item.first == "'" && item.last == "'" || item.first == "\"" && item.last == "\"") {
                    result.append(.key(String(item.dropFirst().dropLast())))
                } else { throw unsupported(raw) }
                path = String(path[path.index(after: end)...])
            } else {
                let name = String(path.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" })
                guard !name.isEmpty else { throw unsupported(raw) }
                result.append(.key(name)); path.removeFirst(name.count)
                guard path.isEmpty || path.hasPrefix(".") || path.hasPrefix("[") else { throw unsupported(raw) }
            }
        }
        guard !result.isEmpty else { throw unsupported(raw) }
        return result
    }

    private static func unsupported(_ rule: String) -> SourceError {
        .message("JSONPath 暂不支持此表达式：\(rule)。当前支持字段、数组索引和 [*]，不支持脚本或过滤器。")
    }

    static func select(_ rule: String, from value: Any) throws -> [Any] {
        var values = [value]
        for token in try tokens(rule) {
            values = values.flatMap { current -> [Any] in
                switch token {
                case .key(let key):
                    guard let item = (current as? [String: Any])?[key] else { return [] }
                    return [item]
                case .index(let index):
                    guard let array = current as? [Any] else { return [] }
                    let resolved = index < 0 ? array.count + index : index
                    return array.indices.contains(resolved) ? [array[resolved]] : []
                case .wildcard:
                    if let array = current as? [Any] { return array }
                    guard let dictionary = current as? [String: Any] else { return [] }
                    return dictionary.keys.sorted().compactMap { dictionary[$0] }
                }
            }
        }
        return values.count == 1 ? ((values[0] as? [Any]) ?? values) : values
    }
}
