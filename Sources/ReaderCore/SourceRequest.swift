import Foundation

public enum SourceRequest {
    public static func make(_ template: String, query: String, base: URL) throws -> URLRequest {
        let split = template.range(of: #",\s*\{"#, options: .regularExpression)
        let path = split.map { String(template[..<$0.lowerBound]) } ?? template
        var options: [String: Any] = [:]
        if let split {
            let json = String(template[template.index(after: split.lowerBound)...])
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw SourceError.message("请求选项必须是 JSON 对象。")
            }
            options = object
        }
        let charset = (options["charset"] as? String ?? "utf-8").lowercased()
        guard ["utf-8", "utf8"].contains(charset) else {
            throw SourceError.message("搜索请求使用 \(charset) 编码，当前仅支持 UTF-8；这不是网络超时。")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        func substitute(_ text: String, encoded: Bool) -> String {
            text.replacingOccurrences(of: "{{key}}", with: encoded ? escaped : query)
                .replacingOccurrences(of: "{{page}}", with: "1")
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
                    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
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
}
