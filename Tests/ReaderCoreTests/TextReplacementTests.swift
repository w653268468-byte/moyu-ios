import XCTest
@testable import ReaderCore

final class TextReplacementTests: XCTestCase {
    func testLiteralRegexCapturesScopeAndUnknownFieldsRoundTrip() throws {
        let input = ##"[{"id":123,"name":"去广告","pattern":"\\[广告[^\\]]*\\]","replacement":"","isRegex":true,"scope":"小说甲,https://site.example","excludeScope":"小说乙","customFutureOption":{"preserve":true}},{"id":124,"name":"章节名","pattern":"第(\\d+)节","replacement":"第$1章","scopeTitle":true,"scopeContent":false,"order":1}]"##
        let parsed = try ReplacementImport.parse(Data(input.utf8))
        XCTAssertEqual(parsed.rules.count, 2); XCTAssertTrue(parsed.failures.isEmpty)
        let transformed = try TransformedReadingText.applying(parsed.rules, to: "[广告入口]正文😀", book: "小说甲", origin: "https://site.example")
        XCTAssertEqual(transformed.text, "正文😀")
        let excluded = try TransformedReadingText.applying(parsed.rules, to: "[广告入口]正文", book: "小说乙", origin: "https://site.example")
        XCTAssertEqual(excluded.text, "[广告入口]正文")
        XCTAssertEqual(try TransformedReadingText.applying(parsed.rules, to: "第12节", book: "小说甲", origin: "", title: true).text, "第12章")
        let object = try JSONSerialization.jsonObject(with: ReplacementImport.export(parsed.rules)) as! [[String: Any]]
        XCTAssertEqual((object[0]["customFutureOption"] as? [String: Bool])?["preserve"], true)
        XCTAssertNil(object[0]["originalJSON"])
        XCTAssertEqual(try ReplacementImport.parse(ReplacementImport.export(parsed.rules)).rules.map(\.id), [123, 124])
    }
    func testMappedOffsetsAcrossChainedReplacementsAndUnicode() throws {
        var remove = TextReplacementRule(name: "移除", pattern: "[广告]", replacement: ""); remove.order = 0
        var expand = TextReplacementRule(name: "扩展", pattern: "这里", replacement: "在这里"); expand.order = 1
        let input = "[广告]😀这里正文最后"
        let result = try TransformedReadingText.applying([expand, remove], to: input, book: "测试", origin: "local")
        XCTAssertEqual(result.text, "😀在这里正文最后")
        for target in ["😀", "正文", "最后"] {
            let original = (input as NSString).range(of: target).location
            let shown = (result.text as NSString).range(of: target).location
            XCTAssertEqual(result.displayOffset(original), shown)
            XCTAssertEqual(result.originalOffset(shown), original)
        }
        XCTAssertEqual(result.displayOffset(Int.max), Int.max)
        XCTAssertEqual(result.originalOffset(Int.max), Int.max)
        XCTAssertEqual(result.originalOffset((result.text as NSString).length), (input as NSString).length)
    }
    func testPartialImportDisabledRulesAndChineseConversion() throws {
        let parsed = try ReplacementImport.parse(Data(#"[{"pattern":"(","isRegex":true},{"name":"替换","pattern":"原文","replacement":"改文","isEnabled":false,"isRegex":false}]"#.utf8))
        XCTAssertEqual(parsed.rules.count, 1); XCTAssertEqual(parsed.failures.count, 1)
        XCTAssertEqual(try TransformedReadingText.applying(parsed.rules, to: "原文", book: "", origin: "").text, "原文")
        XCTAssertEqual(try TransformedReadingText.applying([], to: "國家", book: "", origin: "", conversion: "simplified").text, "国家")
        XCTAssertEqual(try TransformedReadingText.applying([], to: "国家", book: "", origin: "", conversion: "traditional").text, "國家")
    }
    func testSlowRegexIsSkippedWithoutLosingOriginalContent() throws {
        var rule = TextReplacementRule(name: "复杂正则", pattern: "(a+)+$", replacement: "", isRegex: true)
        rule.timeoutMillisecond = 10
        let input = String(repeating: "a", count: 4000) + "!"
        let start = Date()
        let result = try TransformedReadingText.applying([rule], to: input, book: "", origin: "")
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testWhitespaceNormalizationMaintainsOriginalAnchorsAfterReplacement() throws {
        let input = "😀序章\n正文结束"
        let rule = TextReplacementRule(name: "加入空行", pattern: "序章", replacement: "  序章  \n\n  ")
        let output = try TransformedReadingText.applying([rule], to: input, book: "", origin: "").normalizedLines()
        XCTAssertEqual(output.text, TextPagination.readingText(output.text))
        XCTAssertEqual(output.text, "😀  序章\n正文结束")
        let raw = (input as NSString).range(of: "正文").location
        let displayed = (output.text as NSString).range(of: "正文").location
        XCTAssertEqual(output.displayOffset(raw), displayed)
        XCTAssertEqual(output.originalOffset(displayed), raw)
    }
}
