import Foundation
import SwiftSoup

/// A documented CSS subset of Legado's rule language. No remote code is evaluated.
public enum HTMLRule {
    public static func isSupported(_ rule: String) -> Bool {
        let lower = rule.components(separatedBy: "||")
            .map { metadataCSS($0.components(separatedBy: "##")[0]).lowercased() }.joined(separator: "||")
        let isXPath = XPathRule.isXPath(lower)
        let unsupported = ["@js:", "<js>", "{{", "$.", "$[", "@json:", "&&", "%%", "@put:", "@get:"] + (isXPath ? [] : ["@xpath:"])
        // An absolute URL inside a CSS attribute regex is not an XPath axis.
        return !unsupported.contains(where: { lower.contains($0) }) && (isXPath || RuleComposition.split(lower, operator: "//").count == 1)
    }

    public static func elements(_ rule: String, in element: Element) throws -> [Element] {
        guard isSupported(rule) else { throw SourceError.message("暂不支持此规则：\(rule)") }
        if XPathRule.isXPath(rule) { return try XPathRule.elements(rule, in: element) }
        var current = [element]
        for raw in RuleComposition.split(rule.replacingOccurrences(of: "@css:", with: "", options: .caseInsensitive), operator: "@") {
            var selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if selector.isEmpty { continue }
            let indexes = try indexSuffix(&selector)
            var selected: [Element] = []
            for parent in current {
                let found: [Element]
                if selector == "children" || (selector.isEmpty && indexes != nil) { found = parent.children().array() }
                else if selector.hasPrefix("text.") {
                    let needle = String(selector.dropFirst(5))
                    found = try parent.select("*").array().filter { $0.ownText().contains(needle) }
                } else { found = try parent.select(translate(selector)).array() }
                selected += try indexes?.apply(found) ?? found
            }
            current = selected
        }
        return current
    }

    public static func value(_ rule: String?, in element: Element, body: Bool = false) throws -> String {
        guard let rule, !rule.isEmpty else { return "" }
        guard isSupported(rule) else { throw SourceError.message("暂不支持此规则：\(rule)") }
        for alternative in rule.components(separatedBy: "||") {
            let replacements = alternative.components(separatedBy: "##")
            let extraction = metadataCSS(replacements[0]).replacingOccurrences(of: "@css:", with: "", options: .caseInsensitive)
            var parts = RuleComposition.split(extraction, operator: "@")
            let attribute: String
            if parts.count > 1 { attribute = parts.removeLast() }
            else if ["text", "textNodes", "ownText", "html", "href", "src"].contains(parts[0]) {
                attribute = parts.removeLast()
            } else { attribute = "text" }
            let xpath = XPathRule.isXPath(extraction)
            let nodes = xpath ? [] : try elements(parts.joined(separator: "@"), in: element)
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
            var result: String
            if xpath {
                let bodyNodes = body ? try XPathRule.elements(extraction, in: element) : []
                result = bodyNodes.isEmpty
                    ? try XPathRule.evaluate(extraction, in: element, markup: false).joined(separator: body ? "\n\n" : "\n")
                    : try bodyNodes.map { try bodyText($0) }.joined(separator: "\n\n")
            } else { result = values.joined(separator: body ? "\n\n" : "\n") }
            if replacements.count >= 2, !replacements[1].isEmpty {
                result = try RuleReplacement.apply(result, suffix: "##" + replacements.dropFirst().joined(separator: "##"))
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        return ""
    }

    private struct Indexes {
        var entries: [String]; var excluding: Bool; var ranges: Bool
        func apply(_ nodes: [Element]) throws -> [Element] {
            let count = nodes.count
            guard count > 0 else { return [] }
            var ordered: [Int] = [], seen = Set<Int>()
            func append(_ index: Int) { if nodes.indices.contains(index), seen.insert(index).inserted { ordered.append(index) } }
            func number(_ raw: String, fallback: Int) throws -> Int {
                if raw.isEmpty { return fallback }
                guard let value = Int(raw) else { throw SourceError.message("HTML 索引无效。") }
                return value < 0 ? value + count : value
            }
            for entry in entries {
                let values = entry.components(separatedBy: ":")
                if ranges && values.count > 1 {
                    guard values.count <= 3 else { throw SourceError.message("HTML 区间索引格式无效。") }
                    var start = try number(values[0], fallback: 0), end = try number(values[1], fallback: count-1)
                    if (start < 0 && end < 0) || (start >= count && end >= count) { continue }
                    start = min(count-1, max(0, start)); end = min(count-1, max(0, end))
                    let rawStep = values.count == 3 ? Int(values[2]) ?? 1 : 1
                    let step = rawStep > 0 ? rawStep : rawStep > -count ? rawStep + count : 1
                    if start == end || step >= count { append(start); continue }
                    for index in stride(from: start, through: end, by: start <= end ? step : -step) { append(index) }
                } else { for value in values { append(try number(value, fallback: 0)) } }
            }
            return excluding ? nodes.enumerated().filter { !seen.contains($0.offset) }.map(\.element) : ordered.map { nodes[$0] }
        }
    }
    private static func indexSuffix(_ selector: inout String) throws -> Indexes? {
        if let range = selector.range(of: #"\[\s*!?\s*[-\d,:\s]+\]$"#, options: .regularExpression) {
            var expression = String(selector[range].dropFirst().dropLast()).filter { !$0.isWhitespace }
            let excluding = expression.hasPrefix("!")
            if excluding { expression.removeFirst() }
            let entries = expression.components(separatedBy: ",")
            guard entries.count <= 1024, entries.allSatisfy({ !$0.isEmpty }) else { throw SourceError.message("HTML 索引列表无效或过长。") }
            selector = String(selector[..<range.lowerBound])
            return Indexes(entries: entries, excluding: excluding, ranges: true)
        }
        if let range = selector.range(of: #"[.!]-?\d+(?::-?\d+)*$"#, options: .regularExpression) {
            let expression = String(selector[range]); selector = String(selector[..<range.lowerBound])
            return Indexes(entries: String(expression.dropFirst()).components(separatedBy: ":"), excluding: expression.first == "!", ranges: false)
        }
        return nil
    }

    private static func translate(_ rule: String) -> String {
        RuleComposition.split(rule, operator: "@").map { raw in
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
