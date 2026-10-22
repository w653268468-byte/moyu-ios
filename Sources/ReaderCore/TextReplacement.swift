import Foundation

public struct TextReplacementRule: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var group: String?
    public var pattern: String
    public var replacement: String
    public var scope: String?
    public var excludeScope: String?
    public var scopeTitle: Bool
    public var scopeContent: Bool
    public var isEnabled: Bool
    public var isRegex: Bool
    public var timeoutMillisecond: Int
    public var order: Int
    public var originalJSON: String?
    public init(name: String = "新规则", pattern: String = "", replacement: String = "", isRegex: Bool = false) {
        id = Int64.random(in: 1...9_007_199_254_740_991); self.name = name; self.pattern = pattern; self.replacement = replacement
        scopeTitle = false; scopeContent = true; isEnabled = true; self.isRegex = isRegex; timeoutMillisecond = 3000; order = 0
    }
    enum CodingKeys: String, CodingKey {
        case id, name, group, pattern, replacement, scope, excludeScope, scopeTitle, scopeContent, isEnabled, isRegex, timeoutMillisecond, order, originalJSON
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? Int64.random(in: 1...9_007_199_254_740_991)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名规则"
        group = try c.decodeIfPresent(String.self, forKey: .group)
        pattern = try c.decode(String.self, forKey: .pattern)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        excludeScope = try c.decodeIfPresent(String.self, forKey: .excludeScope)
        scopeTitle = try c.decodeIfPresent(Bool.self, forKey: .scopeTitle) ?? false
        scopeContent = try c.decodeIfPresent(Bool.self, forKey: .scopeContent) ?? true
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? true
        timeoutMillisecond = try c.decodeIfPresent(Int.self, forKey: .timeoutMillisecond) ?? 3000
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        originalJSON = try c.decodeIfPresent(String.self, forKey: .originalJSON)
    }
    public func validate() throws {
        guard !pattern.isEmpty, pattern.utf16.count <= 4096 else { throw SourceError.message("规则匹配内容需为 1—4096 个字符。") }
        if isRegex { _ = try NSRegularExpression(pattern: pattern) }
    }
    public func applies(book: String, origin: String, title: Bool) -> Bool {
        guard isEnabled, title ? scopeTitle : scopeContent else { return false }
        func includes(_ value: String) -> Bool {
            (!book.isEmpty && value.range(of: book, options: .caseInsensitive) != nil)
                || (!origin.isEmpty && value.range(of: origin, options: .caseInsensitive) != nil)
        }
        if let excluded = excludeScope, !excluded.isEmpty, includes(excluded) { return false }
        return scope == nil || scope?.isEmpty == true || includes(scope!)
    }
}

public struct ReplacementImport: Sendable {
    public var rules: [TextReplacementRule]
    public var failures: [String]
    public static func parse(_ data: Data) throws -> ReplacementImport {
        guard data.count <= 5 * 1024 * 1024 else { throw SourceError.message("替换规则文件超过 5 MB。") }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch {
            let start = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SourceError.message(start.hasPrefix("<") ? "收到的是网页，并非替换规则 JSON；请使用实际规则文件或原始文件网址。" : "替换规则 JSON 格式不正确，请保留完整对象或数组。")
        }
        let objects: [Any]
        if let array = json as? [Any] { objects = array }
        else if let object = json as? [String: Any], let list = object["replaceRules"] as? [Any] { objects = list }
        else { objects = [json] }
        guard objects.count <= 5000 else { throw SourceError.message("一次最多导入 5000 条替换规则。") }
        var rules: [TextReplacementRule] = [], failures: [String] = [], indices: [Int64: Int] = [:]
        for (index, object) in objects.enumerated() {
            do {
                guard let entry = object as? [String: Any], entry["pattern"] != nil else { throw SourceError.message("缺少 pattern 字段") }
                let encoded = try JSONSerialization.data(withJSONObject: entry)
                var rule = try JSONDecoder().decode(TextReplacementRule.self, from: encoded)
                try rule.validate(); rule.originalJSON = String(decoding: encoded, as: UTF8.self)
                if let existing = indices[rule.id] { rules[existing] = rule }
                else { indices[rule.id] = rules.count; rules.append(rule) }
            } catch { failures.append("第 \(index + 1) 条：\(error.localizedDescription)") }
        }
        return ReplacementImport(rules: rules, failures: failures)
    }
    public static func load(_ input: String) async throws -> ReplacementImport {
        switch try SourceImportInput.detect(input) {
        case .json(let data): return try parse(data)
        case .links(let urls):
            var result = ReplacementImport(rules: [], failures: [])
            for url in urls {
                try Task.checkCancellation()
                do {
                    let (data, _) = try await SourceImportDownload(configuration: .ephemeral, limit: 5 * 1024 * 1024).run(url)
                    let parsed = try parse(data)
                    if result.rules.count + parsed.rules.count > 5000 { result.failures.append("规则合计超过 5000 条，其余网址未获取，请分批导入。"); break }
                    result.rules += parsed.rules; result.failures += parsed.failures
                } catch { try Task.checkCancellation(); result.failures.append("\(url.host ?? "网址")：\(error.localizedDescription)") }
            }
            return result
        }
    }
    public static func export(_ rules: [TextReplacementRule]) throws -> Data {
        let result = try rules.map { rule -> [String: Any] in
            var object = rule.originalJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let known = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
            for (key, value) in known where key != "originalJSON" { object[key] = value }
            for key in ["scope", "excludeScope", "group"] where known[key] == nil { object.removeValue(forKey: key) }
            object.removeValue(forKey: "originalJSON")
            return object
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}

private struct TextReplacementEdit: Sendable { var range: NSRange; var length: Int }
private struct TextReplacementStage: Sendable {
    var inputLength: Int
    var outputLength: Int
    var edits: [TextReplacementEdit]
    func map(_ value: Int, backwards: Bool) -> Int {
        let sourceLength = backwards ? outputLength : inputLength
        let targetLength = backwards ? inputLength : outputLength
        if value == Int.max { return Int.max }
        let offset = min(max(0, value), sourceLength)
        var delta = 0
        for edit in edits {
            let start = backwards ? edit.range.location + delta : edit.range.location
            let oldLength = backwards ? edit.length : edit.range.length
            let newLength = backwards ? edit.range.length : edit.length
            if offset < start { return min(targetLength, max(0, offset + (backwards ? -delta : delta))) }
            if backwards && oldLength == 0 && offset == start { delta += edit.length - edit.range.length; continue }
            if offset <= start + oldLength {
                let relative = oldLength > 0 ? Int((Double(offset - start) / Double(oldLength) * Double(newLength)).rounded()) : 0
                return min(targetLength, max(0, (backwards ? edit.range.location : start + delta) + relative))
            }
            delta += edit.length - edit.range.length
        }
        return min(targetLength, max(0, offset + (backwards ? -delta : delta)))
    }
}

public struct TransformedReadingText: Sendable {
    public var text: String
    public var warnings: [String] = []
    private var stages: [TextReplacementStage] = []
    public init(_ text: String) { self.text = text }
    public func displayOffset(_ original: Int) -> Int { stages.reduce(original) { $1.map($0, backwards: false) } }
    public func originalOffset(_ displayed: Int) -> Int { stages.reversed().reduce(displayed) { $1.map($0, backwards: true) } }
    public func normalizedLines() -> TransformedReadingText {
        let source = text as NSString
        var runs: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let local = (line as NSString).range(of: trimmed)
            runs.append(NSRange(location: range.location + local.location, length: local.length))
        }
        var result = self, pieces: [String] = [], edits: [TextReplacementEdit] = [], cursor = 0
        for (index, run) in runs.enumerated() {
            let gap = NSRange(location: cursor, length: run.location - cursor), replacement = index == 0 ? "" : "\n"
            if gap.length != (replacement as NSString).length || source.substring(with: gap) != replacement { edits.append(TextReplacementEdit(range: gap, length: (replacement as NSString).length)) }
            pieces.append(replacement); pieces.append(source.substring(with: run)); cursor = NSMaxRange(run)
        }
        if cursor < source.length { edits.append(TextReplacementEdit(range: NSRange(location: cursor, length: source.length - cursor), length: 0)) }
        result.text = pieces.joined()
        if !edits.isEmpty { result.stages.append(TextReplacementStage(inputLength: source.length, outputLength: (result.text as NSString).length, edits: edits)) }
        return result
    }
    public static func applying(_ rules: [TextReplacementRule], to input: String, book: String, origin: String, title: Bool = false, conversion: String = "none") throws -> TransformedReadingText {
        var result = TransformedReadingText(input)
        guard input.utf16.count <= 2_000_000 else { result.warnings = ["章节过长，已跳过净化并保留原文。"] ; return result }
        let deadline = Date.timeIntervalSinceReferenceDate + 3
        for rule in rules.sorted(by: { $0.order < $1.order }) where rule.applies(book: book, origin: origin, title: title) {
            try Task.checkCancellation()
            if Date.timeIntervalSinceReferenceDate >= deadline { result.warnings.append("其余净化规则已超过处理时限，保留剩余原文。"); break }
            do {
                try rule.validate()
                let regex = try NSRegularExpression(pattern: rule.isRegex ? rule.pattern : NSRegularExpression.escapedPattern(for: rule.pattern))
                let source = result.text as NSString
                let limit = min(deadline, Date.timeIntervalSinceReferenceDate + Double(max(1, min(3000, rule.timeoutMillisecond))) / 1000)
                var changes: [(NSRange, String)] = [], expired = false, outputLength = source.length
                regex.enumerateMatches(in: result.text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
                    if Date.timeIntervalSinceReferenceDate > limit || Task.isCancelled || changes.count >= 100_000 { expired = true; stop.pointee = true; return }
                    guard let match else { return }
                    let replacement = rule.isRegex ? regex.replacementString(for: match, in: result.text, offset: 0, template: rule.replacement) : rule.replacement
                    outputLength += (replacement as NSString).length - match.range.length
                    if outputLength > 4_000_000 { expired = true; stop.pointee = true; return }
                    changes.append((match.range, replacement))
                }
                try Task.checkCancellation()
                guard !expired else { throw SourceError.message("规则超时或替换内容过多") }
                if changes.isEmpty { continue }
                var pieces: [String] = [], cursor = 0, edits: [TextReplacementEdit] = []
                for (range, replacement) in changes {
                    pieces.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                    pieces.append(replacement); cursor = NSMaxRange(range)
                    edits.append(TextReplacementEdit(range: range, length: (replacement as NSString).length))
                }
                pieces.append(source.substring(from: cursor))
                result.text = pieces.joined()
                result.stages.append(TextReplacementStage(inputLength: source.length, outputLength: outputLength, edits: edits))
            } catch { try Task.checkCancellation(); result.warnings.append("\(rule.name)：\(error.localizedDescription)，已跳过。") }
        }
        if conversion == "simplified" || conversion == "traditional" {
            let original = result.text, name = conversion == "simplified" ? "Traditional-Simplified" : "Simplified-Traditional"
            if let converted = original.applyingTransform(StringTransform(name), reverse: false) {
                let oldLength = (original as NSString).length, newLength = (converted as NSString).length
                result.text = converted
                if oldLength != newLength { result.stages.append(TextReplacementStage(inputLength: oldLength, outputLength: newLength, edits: [TextReplacementEdit(range: NSRange(location: 0, length: oldLength), length: newLength)])) }
            }
        }
        return result
    }
}
