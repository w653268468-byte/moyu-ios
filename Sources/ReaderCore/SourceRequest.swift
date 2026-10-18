import Foundation

public enum SourceRequest {
    public static func make(_ template: String, query: String, base: URL, script: SourceScript? = nil, page: Int = 1) throws -> URLRequest {
        let template = try ScriptTemplate.expand(template, using: script, query: query, base: base, page: page)
        let split = template.range(of: #",\s*\{"#, options: .regularExpression)
        let path = split.map { String(template[..<$0.lowerBound]) } ?? template
        var options: [String: Any] = [:]
        if let split {
            let json = String(template[template.index(after: split.lowerBound)...])
            guard let object = try JSONSerialization.jsonObject(with: optionsData(json)) as? [String: Any] else {
                throw SourceError.message("请求选项必须是 JSON 对象。")
            }
            options = object
        }
        let charset = (options["charset"] as? String ?? "utf-8").lowercased()
        guard ["utf-8", "utf8", "gbk", "gb2312", "gb18030"].contains(charset) else {
            throw SourceError.message("搜索请求使用尚未支持的 \(charset) 编码；这不是网络超时。")
        }
        let encoding: String.Encoding = ["utf-8", "utf8"].contains(charset) ? .utf8 : String.Encoding(rawValue: 0x80000632)
        guard let queryBytes = query.data(using: encoding) else { throw SourceError.message("搜索词无法转换为 \(charset) 编码。") }
        let escaped = queryBytes.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
        func substitute(_ text: String, encoded: Bool) -> String {
            text.replacingOccurrences(of: "{{key}}", with: encoded ? escaped : query)
                .replacingOccurrences(of: "{{page}}", with: String(page))
                .replacingOccurrences(of: "searchKey", with: encoded ? escaped : query)
        }
        let address = substitute(path, encoded: true)
        guard !address.contains("{{"), !address.contains("@js:"), !address.contains("<js>") else {
            throw SourceError.message("搜索网址包含尚未支持的脚本或变量。")
        }
        var request = URLRequest(url: try SourceClient.resolve(address, base: base))
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST"].contains(request.httpMethod!) else { throw SourceError.message("仅支持 GET 和 POST 请求。") }
        if let headers = options["headers"] as? [String: String] {
            for (key, value) in headers where !["cookie", "authorization", "host"].contains(key.lowercased()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = options["body"] {
            guard request.httpMethod == "POST" else { throw SourceError.message("含 body 的请求必须使用 POST。") }
            if let text = body as? String {
                request.httpBody = Data(substitute(text, encoded: true).utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/x-www-form-urlencoded; charset=\(charset)", forHTTPHeaderField: "Content-Type")
                }
            } else {
                func replace(_ value: Any) -> Any {
                    if let text = value as? String { return substitute(text, encoded: false) }
                    if let array = value as? [Any] { return array.map(replace) }
                    if let object = value as? [String: Any] { return object.mapValues(replace) }
                    return value
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: replace(body))
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    // Legado commonly uses JSON-like request options with single-quoted strings.
    // Normalize only string literals; no JavaScript is evaluated here.
    private static func optionsData(_ raw: String) throws -> Data {
        if (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) != nil { return Data(raw.utf8) }
        let chars = Array(raw)
        var output = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard char == "'" || char == "\"" else { output.append(char); index += 1; continue }
            let quote = char
            index += 1
            var string = ""
            var closed = false
            while index < chars.count {
                let current = chars[index]; index += 1
                if current == quote { closed = true; break }
                if current == "\\" {
                    guard index < chars.count else { break }
                    let escaped = chars[index]; index += 1
                    switch escaped {
                    case "n": string.append("\n")
                    case "r": string.append("\r")
                    case "t": string.append("\t")
                    case "u":
                        guard index + 4 <= chars.count,
                              let number = UInt32(String(chars[index..<(index + 4)]), radix: 16),
                              let scalar = UnicodeScalar(number) else { throw SourceError.message("请求选项包含无效的 Unicode 转义。") }
                        string.unicodeScalars.append(scalar); index += 4
                    default: string.append(escaped)
                    }
                } else { string.append(current) }
            }
            guard closed else { throw SourceError.message("请求选项包含未闭合字符串。") }
            let encoded = try JSONSerialization.data(withJSONObject: [string])
            output += String(String(data: encoded, encoding: .utf8)!.dropFirst().dropLast())
        }
        return Data(output.utf8)
    }
}
