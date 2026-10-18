import Foundation
import CoreFoundation

/// A data-only JSONPath evaluator. Filters never execute source JavaScript.
enum JSONPath {
    indirect enum Selector {
        case key(String), index(Int), wildcard, slice(Int?, Int?, Int)
        case filter(Expression), union([Selector]), descendant(Selector)
    }
    indirect enum Expression {
        case or(Expression, Expression), and(Expression, Expression), not(Expression)
        case compare(Operand, String, Operand), test(Operand)
    }
    indirect enum Operand {
        case literal(Any), query(Bool, [Selector]), function(String, [Operand])
    }
    enum Value { case missing, node(Any), nodes([Any]) }

    static func compile(_ raw: String) throws -> [Selector] {
        guard raw.count <= 16000 else { throw error("表达式过长") }
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("@json:") { input.removeFirst(6) }
        if input == "text" { input = "$" }
        let parser = Parser(input)
        let result = try parser.path(implicitRoot: true)
        parser.spaces()
        guard parser.ended else { throw error("无法识别的位置：\(parser.remaining.prefix(40))") }
        return result.1
    }

    static func select(_ raw: String, from value: Any) throws -> [Any] {
        try evaluate(compile(raw), nodes: [value], root: value)
    }

    /// Legado alternatives are outside selectors; `||` inside a filter is logical OR.
    static func alternatives(_ rule: String) -> [String] {
        let chars = Array(rule)
        var result: [String] = [], start = 0, level = 0, quote: Character?, escaped = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "[" || c == "(" { level += 1 }
            else if c == "]" || c == ")" { level -= 1 }
            else if level == 0 && c == "|" && i + 1 < chars.count && chars[i + 1] == "|" {
                result.append(String(chars[start..<i])); i += 1; start = i + 1
            }
            i += 1
        }
        result.append(String(chars[start...]))
        return result
    }

    private static func error(_ detail: String) -> SourceError { .message("JSONPath：\(detail)。") }

    private final class Parser {
        let chars: [Character]
        var i = 0
        var depth = 0
        init(_ value: String) { chars = Array(value) }
        var ended: Bool { i >= chars.count }
        var remaining: String { String(chars.dropFirst(i)) }
        var current: Character? { ended ? nil : chars[i] }
        func spaces() { while current?.isWhitespace == true { i += 1 } }
        @discardableResult func take(_ token: String) -> Bool {
            let part = Array(token)
            guard i + part.count <= chars.count, Array(chars[i..<(i + part.count)]) == part else { return false }
            i += part.count; return true
        }
        func require(_ token: String) throws { spaces(); guard take(token) else { throw error("需要 \(token)，实际为 \(remaining.prefix(30))") } }
        func nested<T>(_ body: () throws -> T) throws -> T {
            depth += 1; defer { depth -= 1 }
            guard depth <= 64 else { throw error("嵌套超过 64 层") }
            return try body()
        }
        func identifier() throws -> String {
            let start = i
            while let c = current, c.isLetter || c.isNumber || c == "_" || c == "-" || c == ":" { i += 1 }
            guard i > start else { throw error("缺少字段名称") }
            return String(chars[start..<i])
        }
        func string() throws -> String {
            guard let quote = current, quote == "'" || quote == "\"" else { throw error("需要字符串") }
            i += 1
            var escaped = false, raw = "\""
            while let c = current {
                i += 1
                if escaped {
                    if c == "'" && quote == "'" { raw += "'" }
                    else if c == "\"" { raw += "\\\"" }
                    else { raw += "\\" + String(c) }
                    escaped = false
                } else if c == "\\" { escaped = true }
                else if c == quote {
                    raw += "\""
                    guard let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { throw error("字符串转义无效") }
                    return value
                } else if c == "\"" { raw += "\\\"" }
                else { raw.append(c) }
            }
            throw error("字符串没有结束")
        }
        func integer() throws -> Int {
            let start = i
            _ = take("-")
            while current?.isNumber == true { i += 1 }
            guard let value = Int(String(chars[start..<i])) else { throw error("数组索引无效") }
            return value
        }
        func path(implicitRoot: Bool = false) throws -> (Bool, [Selector]) {
            spaces()
            var root = true
            if take("$") { root = true }
            else if take("@") { root = false }
            else if !implicitRoot { throw error("路径需以 $ 或 @ 开始") }
            var selectors: [Selector] = []
            if implicitRoot, current != nil, current != ".", current != "[", i == 0 {
                selectors.append(.key(try identifier()))
            }
            while !ended {
                if take("..") {
                    let child: Selector
                    if take("*") { child = .wildcard }
                    else if take("[") { child = try bracket() }
                    else { child = .key(try identifier()) }
                    selectors.append(.descendant(child))
                } else if take(".") {
                    selectors.append(take("*") ? .wildcard : .key(try identifier()))
                } else if take("[") { selectors.append(try bracket()) }
                else { break }
                guard selectors.count <= 256 else { throw error("路径过长") }
            }
            return (root, selectors)
        }
        func bracket() throws -> Selector {
            try nested {
                var items: [Selector] = []
                repeat {
                    spaces()
                    if take("?") { items.append(.filter(try expression())) }
                    else if take("*") { items.append(.wildcard) }
                    else if current == "'" || current == "\"" { items.append(.key(try string())) }
                    else {
                        let start: Int? = current == ":" ? nil : try integer()
                        spaces()
                        if take(":") {
                            spaces()
                            let end: Int? = current == ":" || current == "]" || current == "," ? nil : try integer()
                            spaces()
                            var step = 1
                            if take(":") {
                                spaces()
                                if current != "]" && current != "," { step = try integer() }
                            }
                            items.append(.slice(start, end, step))
                        } else if let start { items.append(.index(start)) }
                        else { throw error("无效数组选择器") }
                    }
                    spaces()
                } while take(",")
                try require("]")
                return items.count == 1 ? items[0] : .union(items)
            }
        }
        func expression() throws -> Expression {
            var value = try conjunction()
            spaces()
            while take("||") { value = .or(value, try conjunction()); spaces() }
            return value
        }
        func conjunction() throws -> Expression {
            var value = try unary()
            spaces()
            while take("&&") { value = .and(value, try unary()); spaces() }
            return value
        }
        func unary() throws -> Expression {
            try nested {
                spaces()
                if take("!") { return .not(try unary()) }
                if take("(") { let value = try expression(); try require(")"); return value }
                let left = try operand()
                spaces()
                for op in ["==", "!=", "<=", ">=", "<", ">"] {
                    if take(op) { return .compare(left, op, try operand()) }
                }
                return .test(left)
            }
        }
        func operand() throws -> Operand {
            try nested {
                spaces()
                if current == "$" || current == "@" { let query = try path(); return .query(query.0, query.1) }
                if current == "'" || current == "\"" { return .literal(try string()) }
                for (token, value) in [("true", true as Any), ("false", false as Any), ("null", NSNull() as Any)] {
                    if take(token) { return .literal(value) }
                }
                if current == "-" || current?.isNumber == true {
                    let start = i
                    while let c = current, c.isNumber || ".-+eE".contains(c) { i += 1 }
                    let raw = String(chars[start..<i])
                    guard let data = raw.data(using: .utf8), let number = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? NSNumber else { throw error("数字无效") }
                    return .literal(number)
                }
                let name = try identifier()
                guard ["length", "count", "value", "match", "search"].contains(name) else { throw error("未知过滤函数 \(name)") }
                try require("(")
                var args: [Operand] = []
                spaces()
                if !take(")") {
                    repeat { args.append(try operand()); spaces() } while take(",")
                    try require(")")
                }
                guard args.count == (["match", "search"].contains(name) ? 2 : 1) else { throw error("\(name) 参数数量不正确") }
                return .function(name, args)
            }
        }
    }

    private static func children(_ node: Any) -> [Any] {
        if let array = node as? [Any] { return array }
        if let object = node as? [String: Any] { return object.keys.sorted().compactMap { object[$0] } }
        return []
    }

    private static func evaluate(_ selectors: [Selector], nodes: [Any], root: Any, depth: Int = 0) throws -> [Any] {
        guard depth <= 256 else { throw error("JSON 嵌套超过 256 层") }
        var nodes = nodes
        for selector in selectors {
            try Task.checkCancellation()
            var next: [Any] = []
            for node in nodes {
                next += try apply(selector, node: node, root: root, depth: depth)
                guard next.count <= 100000 else { throw error("匹配结果超过 100000 项") }
            }
            nodes = next
        }
        return nodes
    }

    private static func apply(_ selector: Selector, node: Any, root: Any, depth: Int) throws -> [Any] {
        switch selector {
        case .key(let key): return (node as? [String: Any])?[key].map { [$0] } ?? []
        case .index(let index):
            guard let array = node as? [Any] else { return [] }
            let position = index < 0 ? array.count + index : index
            return array.indices.contains(position) ? [array[position]] : []
        case .wildcard: return children(node)
        case .union(let selectors):
            var result: [Any] = []
            for item in selectors {
                result += try apply(item, node: node, root: root, depth: depth)
                guard result.count <= 100000 else { throw error("匹配结果超过 100000 项") }
            }
            return result
        case .descendant(let child):
            guard depth < 256 else { throw error("JSON 嵌套超过 256 层") }
            var values = try apply(child, node: node, root: root, depth: depth)
            for item in children(node) {
                values += try apply(selector, node: item, root: root, depth: depth + 1)
                guard values.count <= 100000 else { throw error("匹配结果超过 100000 项") }
            }
            return values
        case .filter(let expression):
            return try children(node).filter { try truth(expression, node: $0, root: root, depth: depth) }
        case .slice(let start, let end, let step):
            guard let array = node as? [Any], step != 0 else { return [] }
            let count = array.count
            func normalized(_ index: Int, lower: Int, upper: Int) -> Int {
                min(upper, max(lower, index < 0 ? max(-1, count + max(-count - 1, index)) : index))
            }
            var result: [Any] = []
            if step > 0 {
                var i = normalized(start ?? 0, lower: 0, upper: count)
                let last = normalized(end ?? count, lower: 0, upper: count)
                while i < last {
                    result.append(array[i])
                    if step > last - i { break }; i += step
                }
            } else {
                var i = start.map { normalized($0, lower: -1, upper: count - 1) } ?? (count - 1)
                let last = end.map { normalized($0, lower: -1, upper: count - 1) } ?? -1
                while i > last {
                    result.append(array[i])
                    if step < last - i { break }; i += step
                }
            }
            return result
        }
    }

    private static func scalar(_ value: Value) -> Value {
        if case .nodes(let nodes) = value { return nodes.count == 1 ? .node(nodes[0]) : .missing }
        return value
    }
    private static func bool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private static func equal(_ left: Value, _ right: Value) -> Bool {
        switch (scalar(left), scalar(right)) {
        case (.missing, .missing): return true
        case (.node(let a), .node(let b)):
            if a is NSNull { return b is NSNull }
            if let a = a as? NSNumber, let b = b as? NSNumber { return bool(a) == bool(b) && a.compare(b) == .orderedSame }
            if let a = a as? String, let b = b as? String { return a == b }
            if let a = a as? [Any], let b = b as? [Any] { return a.count == b.count && zip(a, b).allSatisfy { equal(.node($0.0), .node($0.1)) } }
            if let a = a as? [String: Any], let b = b as? [String: Any] { return a.keys.sorted() == b.keys.sorted() && a.allSatisfy { equal(.node($0.value), .node(b[$0.key]!)) } }
            return false
        default: return false
        }
    }
    private static func compare(_ a: Value, _ op: String, _ b: Value) -> Bool {
        if op == "==" { return equal(a, b) }
        if op == "!=" { return !equal(a, b) }
        guard case .node(let left) = scalar(a), case .node(let right) = scalar(b) else { return false }
        let order: ComparisonResult
        if let left = left as? NSNumber, let right = right as? NSNumber, !bool(left), !bool(right) { order = left.compare(right) }
        else if let left = left as? String, let right = right as? String { order = left.compare(right, options: .literal) }
        else { return false }
        switch op {
        case "<": return order == .orderedAscending
        case ">": return order == .orderedDescending
        case "<=": return order != .orderedDescending
        case ">=": return order != .orderedAscending
        default: return false
        }
    }
    private static func truth(_ expression: Expression, node: Any, root: Any, depth: Int) throws -> Bool {
        switch expression {
        case .or(let a, let b): return try truth(a, node: node, root: root, depth: depth) || truth(b, node: node, root: root, depth: depth)
        case .and(let a, let b): return try truth(a, node: node, root: root, depth: depth) && truth(b, node: node, root: root, depth: depth)
        case .not(let value): return try !truth(value, node: node, root: root, depth: depth)
        case .compare(let a, let op, let b): return try compare(resolve(a, node: node, root: root, depth: depth), op, resolve(b, node: node, root: root, depth: depth))
        case .test(let operand):
            switch try resolve(operand, node: node, root: root, depth: depth) {
            case .nodes(let values): return !values.isEmpty
            case .node(let value): return (value as? NSNumber).map { bool($0) && $0.boolValue } ?? false
            case .missing: return false
            }
        }
    }
    private static func resolve(_ operand: Operand, node: Any, root: Any, depth: Int) throws -> Value {
        switch operand {
        case .literal(let value): return .node(value)
        case .query(let isRoot, let selectors): return .nodes(try evaluate(selectors, nodes: [isRoot ? root : node], root: root, depth: depth))
        case .function(let name, let operands):
            let args = try operands.map { try resolve($0, node: node, root: root, depth: depth) }
            if name == "count" { if case .nodes(let list) = args[0] { return .node(NSNumber(value: list.count)) }; return .missing }
            if name == "value" { return scalar(args[0]) }
            if name == "length", case .node(let value) = scalar(args[0]) {
                if let value = value as? String { return .node(NSNumber(value: value.unicodeScalars.count)) }
                if let value = value as? [Any] { return .node(NSNumber(value: value.count)) }
                if let value = value as? [String: Any] { return .node(NSNumber(value: value.count)) }
            }
            if ["match", "search"].contains(name), case .node(let first) = scalar(args[0]), case .node(let second) = scalar(args[1]),
               let text = first as? String, let pattern = second as? String {
                guard pattern.count <= 2000 else { throw error("正则表达式过长") }
                let regex = try NSRegularExpression(pattern: name == "match" ? "\\A(?:\(pattern))\\z" : pattern)
                return .node(NSNumber(value: regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil))
            }
            return .missing
        }
    }
}
