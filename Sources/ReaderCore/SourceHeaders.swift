import Foundation

enum SourceHeaders {
    static func parse(_ text: String) throws -> [String: String] {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 64 * 1024 else { throw SourceError.message("请求头超过 64 KB。") }
        let values: [String: String]
        if raw.isEmpty { return [:] }
        if raw.hasPrefix("{") { values = try JSONDecoder().decode([String: String].self, from: SourceRequest.optionsData(raw)) }
        else { values = ["User-Agent": raw] }
        guard values.count <= 64 else { throw SourceError.message("请求头数量过多。") }
        for (name, value) in values {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || "!#$%&'*+-.^_`|~".unicodeScalars.contains($0)) }),
                  !value.contains("\r"), !value.contains("\n") else { throw SourceError.message("请求头名称或取值无效。") }
        }
        return values
    }
}
