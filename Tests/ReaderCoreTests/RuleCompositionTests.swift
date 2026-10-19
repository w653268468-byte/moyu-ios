import Foundation
import XCTest
@testable import ReaderCore

final class RuleCompositionTests: XCTestCase {
    private let base = URL(string: "https://fixture.example")!
    func testInlineSelectorAndJavaScriptTemplatesMatchImportedPatterns() throws {
        let doc = try RuleDocument.parse(Data("<div class='tagList'>科幻</div><div id='novel_intro'><p>故事简介</p></div>".utf8), base: base)
        let template = "标签：{{@class.tagList.0@text}}{{'\\n'+''}}{{@#novel_intro@text}}"
        XCTAssertTrue(RuleComposition.isSupported(template))
        XCTAssertEqual(try doc.value(template), "标签：科幻\n故事简介")
        XCTAssertEqual(try doc.value("{{@class.tagList.0@text}}##科幻##幻想"), "幻想")
        let json = try RuleDocument.parse(Data(#"{"bookUrl":"/book/1"}"#.utf8), base: base)
        XCTAssertEqual(try json.value("{{$.bookUrl}}&newWebview=1"), "/book/1&newWebview=1")
    }
    func testOperatorsRespectFiltersStringsAndScriptExpressions() throws {
        let doc = try RuleDocument.parse(Data("<b>A</b><b>B</b><i>1</i><i>2</i>".utf8), base: base)
        XCTAssertEqual(try doc.value("b@text&&i@text"), "A\nB\n1\n2")
        XCTAssertEqual(try doc.value("b@text%%i@text"), "A\n1\nB\n2")
        XCTAssertEqual(try doc.elements("b%%i").map { try $0.value("text") }, ["A","1","B","2"])
        XCTAssertEqual(try doc.value(".missing@text||b@text"), "A\nB")
        XCTAssertEqual(RuleComposition.split("$.books[?(@.a || @.b)]", operator: "||").count, 1)
        XCTAssertEqual(RuleComposition.split("@js:result || 'fallback'", operator: "||").count, 1)
        XCTAssertEqual(RuleComposition.split("{{'A&&B'}}&&b@text", operator: "&&").count, 2)
    }
    func testVariablesRawRegexFirstMatchAndExcludedElements() throws {
        let script = try SourceScript()
        let json = try RuleDocument.parse(Data(#"{"bookId":42}"#.utf8), base: base, script: script)
        XCTAssertEqual(try json.value("@put:{bid:$.bookId}"), "")
        XCTAssertEqual(try json.value("@get:{bid}"), "42")
        XCTAssertEqual(try json.value("https://fixture.example/toc?bid=@get:{bid}"), "https://fixture.example/toc?bid=42")
        let restored = try SourceScript(); try restored.restoreVariables(script.snapshotVariables())
        XCTAssertEqual(restored.variable("bid"), "42")
        let html = try RuleDocument.parse(Data("<p>字数：123<em>正文</em></p><div class='textlist'>广告</div><div class='textlist'>章节</div>".utf8), base: base)
        XCTAssertEqual(try html.value("##字数：([0-9]+)##$1###"), "123")
        XCTAssertEqual(try html.elements(".textlist!0").map { try $0.value("text") }, ["章节"])
        XCTAssertThrowsError(try html.value("{{'unclosed'"))
    }
}
