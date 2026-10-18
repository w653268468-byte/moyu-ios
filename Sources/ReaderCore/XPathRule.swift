import Foundation
import SwiftSoup
import CReaderXML

public enum XPathRule {
    public static func isXPath(_ rule: String) -> Bool {
        let lower = rule.lowercased()
        return lower.hasPrefix("@xpath:") || lower.hasPrefix("//") || lower.hasPrefix(".//") || lower.hasPrefix("./")
    }
    static func evaluate(_ rule: String, in element: Element, markup: Bool) throws -> [String] {
        var expression = rule
        if expression.lowercased().hasPrefix("@xpath:") { expression.removeFirst(7) }
        guard expression.utf8.count <= 16000 else { throw SourceError.message("XPath 表达式过长。") }
        let html = try element.outerHtml()
        let result = html.withCString { source in
            expression.withCString { xpath in gavin_xpath(source, xpath, markup ? 1 : 0, element is Document ? 1 : 0) }
        }
        guard let result else { throw SourceError.message("XPath 内存不足。") }
        defer { gavin_xpath_free(result) }
        if let error = result.pointee.error { throw SourceError.message("XPath 解析失败：\(String(cString: error)) · \(rule)") }
        guard let values = result.pointee.values else { return [] }
        return (0..<Int(result.pointee.count)).compactMap { index in values[index].map { String(cString: $0) } }
    }
    static func elements(_ rule: String, in element: Element) throws -> [Element] {
        try evaluate(rule, in: element, markup: true).compactMap { markup in
            let doc: Document
            if markup.lowercased().hasPrefix("<tr") { doc = try SwiftSoup.parse("<table><tbody>\(markup)</tbody></table>"); return try doc.select("tr").first() }
            if markup.lowercased().hasPrefix("<td") { doc = try SwiftSoup.parse("<table><tbody><tr>\(markup)</tr></tbody></table>"); return try doc.select("td").first() }
            doc = try SwiftSoup.parseBodyFragment(markup)
            return doc.body()?.children().first()
        }
    }
}
