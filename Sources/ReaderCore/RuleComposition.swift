import Foundation

enum RuleReplacement {
    static func apply(_ text: String, suffix: String) throws -> String {
        let parts = suffix.components(separatedBy: "##")
        let index = suffix.hasPrefix("##") ? 1 : 0
        guard parts.indices.contains(index), !parts[index].isEmpty else { return text }
        let regex = try NSRegularExpression(pattern: parts[index])
        var replacement = parts.indices.contains(index + 1) ? parts[index + 1] : ""
        if suffix.hasSuffix("###") {
            if replacement.hasSuffix("#") { replacement.removeLast() }
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return "" }
            return regex.replacementString(for: match, in: text, offset: 0, template: replacement)
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

enum RuleComposition {
    struct TemplatePart { var literal: String?; var expression: String? }
    static func split(_ text: String, operator token: String) -> [String] {
        let chars = Array(text), needle = Array(token)
        var parts: [String] = [], start = 0, i = 0, depth = 0
        var quote: Character?, escaped = false, script = false
        while i < chars.count {
            func matches(_ value: String) -> Bool { let part = Array(value); return i + part.count <= chars.count && Array(chars[i..<(i + part.count)]) == part }
            if !script && quote == nil && depth == 0 && (matches("@js:") || matches("##")) { break }
            if !script && matches("<js>") { script = true; i += 4; continue }
            if script { if matches("</js>") { script = false; i += 5 } else { i += 1 }; continue }
            let char = chars[i]
            if let q = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == q { quote = nil }
            } else if char == "'" || char == "\"" || char == "`" { quote = char }
            else if "([{".contains(char) { depth += 1 }
            else if ")] }".replacingOccurrences(of: " ", with: "").contains(char) { depth = max(0, depth - 1) }
            else if depth == 0 && i + needle.count <= chars.count && Array(chars[i..<(i + needle.count)]) == needle {
                parts.append(String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)); i += needle.count; start = i; continue
            }
            i += 1
        }
        parts.append(String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }
    static func templates(_ text: String) throws -> [TemplatePart] {
        let chars = Array(text)
        var result: [TemplatePart] = [], i = 0, start = 0
        while i + 1 < chars.count {
            guard chars[i] == "{", chars[i + 1] == "{" else { i += 1; continue }
            if i > start { result.append(TemplatePart(literal: String(chars[start..<i]))) }
            i += 2; let codeStart = i
            var braces = 0, escaped = false; var quote: Character?
            while i < chars.count {
                let char = chars[i]
                if let q = quote {
                    if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == q { quote = nil }
                } else if char == "'" || char == "\"" || char == "`" { quote = char }
                else if char == "{" { braces += 1 }
                else if char == "}" {
                    if braces > 0 { braces -= 1 }
                    else if i + 1 < chars.count && chars[i + 1] == "}" { break }
                }
                i += 1
            }
            guard i + 1 < chars.count, result.count < 200 else { throw SourceError.message("提取模板缺少 }} 或变量过多。") }
            result.append(TemplatePart(expression: String(chars[codeStart..<i])))
            i += 2; start = i
        }
        if start < chars.count { result.append(TemplatePart(literal: String(chars[start...]))) }
        return result
    }
    static func isSupported(_ rule: String) -> Bool {
        if rule.contains("{{") { return (try? templates(rule)) != nil }
        if rule.contains("@get:{") || rule.hasPrefix("@put:") || rule.hasPrefix("##") { return true }
        for op in ["||", "&&", "%%"] {
            let parts = split(rule, operator: op)
            if parts.count > 1 { return parts.allSatisfy { HTMLRule.isSupported($0) || JSONRule.isSupported($0) || ScriptRule.isSupported($0) || isSupported($0) } }
        }
        return false
    }
}
