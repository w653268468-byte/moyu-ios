import Foundation

enum ScriptTemplate {
    static func needsScript(_ template: String) -> Bool {
        let lower = template.lowercased()
        return lower.contains("@js:") || lower.contains("<js>") || lower.contains("@put:") || lower.contains("@get:") || (template.replacingOccurrences(of: "{{key}}", with: "").replacingOccurrences(of: "{{page}}", with: "").contains("{{"))
    }
    static func expand(_ template: String, using script: SourceScript?, query: String, base: URL, page: Int = 1) throws -> String {
        guard needsScript(template) else { return template }
        guard let script else { throw SourceError.message("请求需要 JavaScript 引擎。") }
        try script.setJSONGlobal("page", json: String(page))
        func run(_ code: String, input: String = "") throws -> String {
            let result = try script.evaluate(code, result: input, baseURL: base, globals: ["key": query])
            if let string = result as? String { return string }
            if result is NSNull { return "" }
            return String(decoding: try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed), as: UTF8.self)
        }
        if let parts = try ScriptRule.parts(template) {
            if parts.suffix.isEmpty { return try run(parts.code, input: parts.prefix) }
            guard ["http://", "https://", "/", "./", "../"].contains(where: parts.suffix.hasPrefix) else { throw SourceError.message("网址脚本之后含提取规则，请把规则放到正文或列表字段。") }
            let value = try run(parts.code, input: parts.prefix)
            return try expand(parts.suffix.replacingOccurrences(of: "{{result}}", with: value), using: script, query: query, base: base, page: page)
        }
        let chars = Array(template)
        var i = 0, output = "", count = 0
        while i < chars.count {
            guard i + 1 < chars.count, chars[i] == "{", chars[i + 1] == "{" else { output.append(chars[i]); i += 1; continue }
            let start = i
            i += 2
            let codeStart = i
            var quote: Character?, escaped = false, braces = 0
            while i < chars.count {
                let char = chars[i]
                if let q = quote {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == q { quote = nil }
                } else if char == "'" || char == "\"" || char == "`" { quote = char }
                else if char == "{" { braces += 1 }
                else if char == "}" {
                    if braces > 0 { braces -= 1 }
                    else if i + 1 < chars.count, chars[i + 1] == "}" { break }
                }
                i += 1
            }
            guard i + 1 < chars.count else { throw SourceError.message("请求模板缺少 }}。") }
            let code = String(chars[codeStart..<i])
            i += 2; count += 1
            guard count <= 100 else { throw SourceError.message("请求模板变量过多。") }
            if code == "key" || code == "page" { output += String(chars[start..<i]) }
            else { output += try run(code) }
            guard output.utf8.count <= 512 * 1024 else { throw SourceError.message("请求模板结果过大。") }
        }
        return output
    }
}
