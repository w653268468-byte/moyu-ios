import Foundation
import SwiftSoup

/// A documented CSS subset of Legado's rule language. No remote code is evaluated.
public enum HTMLRule {
    public static func isSupported(_ rule: String) -> Bool {
        let lower = rule.components(separatedBy: "||")
            .map { metadataCSS($0.components(separatedBy: "##")[0]).lowercased() }.joined(separator: "||")
        return !["@js:", "<js>", "{{", "$.", "$[", "//", "@xpath:", "@json:", "&&", "%%", "@put:", "@get:"].contains(where: { lower.contains($0) })
    }

    public static func elements(_ rule: String, in element: Element) throws -> [Element] {
        guard isSupported(rule) else { throw SourceError.message("暂不支持此规则：\(rule)") }
        var current = [element]
        for raw in rule.replacingOccurrences(of: "@css:", with: "").components(separatedBy: "@") {
            var selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if selector.isEmpty { continue }
            var index: Int?
            if let range = selector.range(of: #"\.(-?\d+)$"#, options: .regularExpression) {
                index = Int(selector[range].dropFirst())
                selector = String(selector[..<range.lowerBound])
            } else if let range = selector.range(of: #"\[(-?\d+)\]$"#, options: .regularExpression) {
                index = Int(selector[range].dropFirst().dropLast())
                selector = String(selector[..<range.lowerBound])
            }
            var selected: [Element] = []
            for parent in current {
                if selector == "children" { selected += parent.children().array() }
                else if selector.hasPrefix("text.") {
                    let needle = String(selector.dropFirst(5))
                    selected += try parent.select("*").array().filter { $0.ownText().contains(needle) }
                } else { selected += try parent.select(translate(selector)).array() }
            }
            // Legacy .0 / .-1 index the matched collection, not the node's sibling position.
            if let index {
                let resolved = index < 0 ? selected.count + index : index
                current = selected.indices.contains(resolved) ? [selected[resolved]] : []
            } else { current = selected }
        }
        return current
    }

    public static func value(_ rule: String?, in element: Element, body: Bool = false) throws -> String {
        guard let rule, !rule.isEmpty else { return "" }
        guard isSupported(rule) else { throw SourceError.message("暂不支持此规则：\(rule)") }
        for alternative in rule.components(separatedBy: "||") {
            let replacements = alternative.components(separatedBy: "##")
            let extraction = metadataCSS(replacements[0]).replacingOccurrences(of: "@css:", with: "")
            var parts = extraction.components(separatedBy: "@")
            let attribute: String
            if parts.count > 1 { attribute = parts.removeLast() }
            else if ["text", "textNodes", "ownText", "html", "href", "src"].contains(parts[0]) {
                attribute = parts.removeLast()
            } else { attribute = "text" }
            let nodes = try elements(parts.joined(separator: "@"), in: element)
            var values: [String] = []
            for node in nodes {
                switch attribute {
                case "text":
                    values.append(try (body ? bodyText(node) : node.text()))
                case "textNodes", "ownText": values.append(try (body ? bodyText(node) : node.ownText()))
                case "html": values.append(try (body ? bodyText(node) : node.html()))
                default: values.append(try node.attr(attribute))
                }
            }
            var result = values.joined(separator: body ? "\n\n" : "\n")
            if replacements.count >= 2, !replacements[1].isEmpty {
                let regex = try NSRegularExpression(pattern: replacements[1])
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: replacements.count >= 3 ? replacements[2] : "")
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        return ""
    }

    private static func translate(_ rule: String) -> String {
        rule.components(separatedBy: "@").map { raw in
            var selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Common old-style Legado selectors: class.name, id.name, tag.a and .0 indices.
            for (prefix, replacement) in [("class.", "."), ("id.", "#"), ("tag.", "")] {
                if selector.hasPrefix(prefix) { selector = replacement + selector.dropFirst(prefix.count); break }
            }
            return selector
        }.joined(separator: " ")
    }

    private static func metadataCSS(_ rule: String) -> String {
        // Recognize only the common metadata XPath shape; general XPath stays unsupported.
        let pattern = #"^//meta\[@(property|name)\s*=\s*['\"]([^'\"]+)['\"]\]/@([A-Za-z0-9:_-]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rule, range: NSRange(rule.startIndex..., in: rule)),
              let field = Range(match.range(at: 1), in: rule),
              let name = Range(match.range(at: 2), in: rule),
              let attr = Range(match.range(at: 3), in: rule) else { return rule }
        return "meta[\(rule[field])=\"\(rule[name])\"]@\(rule[attr])"
    }

    private static func bodyText(_ element: Element) throws -> String {
        // Parse a copy so cleanup cannot mutate the catalog/search DOM.
        let copy = try SwiftSoup.parseBodyFragment(element.html())
        try copy.select("script, style, noscript, iframe").remove()
        try copy.select("br").before(" MOYU_LINE_BREAK ")
        try copy.select("p, div, li").prepend(" MOYU_LINE_BREAK ")
        return try copy.text().components(separatedBy: "MOYU_LINE_BREAK")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
