import Foundation
import XCTest
@testable import ReaderCore

final class RuleCompositionTests: XCTestCase {
    func testURLPreludeCanClearCookiesBeforeLiteralPOSTAndPreserveSearchVariables() throws {
        let script = try SourceScript()
        let template = "<js>java.put('prelude','ran');cookie.removeCookie('https://fixture.example');</js>/search/,{\"method\":\"POST\",\"body\":\"searchkey={{key}}&page={{page}}\"}"
        let request = try SourceRequest.make(template, query: "我的故事", base: URL(string: "https://fixture.example")!, script: script, page: 3)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.example/search/")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "searchkey=%E6%88%91%E7%9A%84%E6%95%85%E4%BA%8B&page=3")
        XCTAssertEqual(script.variable("prelude"), "ran")
        XCTAssertThrowsError(try SourceRequest.make("<js>'value'</js>$.title", query: "", base: request.url!, script: script))
    }
    func testCSSAttributeRegexContainingAbsoluteURLIsNotRejectedAsXPath() throws {
        let rule = #"@css:a[href~=^/book/[0-9]+\.html$]:matchesOwn(.+),a[href~=^https?://(www\.)?biquge\.tw/book/[0-9]+\.html$]:matchesOwn(.+)"#
        let html = "<a href='/book/12.html'>相对</a><a href='https://www.biquge.tw/book/34.html'>绝对</a><a href='https://other.example/book/56.html'>其他</a><a href='/book/78.html'></a>"
        let doc = try RuleDocument.parse(Data(html.utf8), base: URL(string: "https://www.biquge.tw")!)
        XCTAssertTrue(HTMLRule.isSupported(rule))
        XCTAssertEqual(try doc.elements(rule).map { try $0.value("text") }, ["相对", "绝对"])
    }
    func testLegacyScriptThenLiteralURLUsesScriptResultAndOriginalJSONSelectors() throws {
        let engine = try SourceScript()
        let doc = try RuleDocument.parse(Data(#"{"Id":1234,"name":"正常书名"}"#.utf8), base: URL(string: "https://fixture.example")!, script: engine)
        let url = "<js>java.put('cid',Math.floor({{$.Id}}/1000)+1)</js>https://fixture.example/{{result}}/{{$.Id}}/info.html"
        XCTAssertEqual(try doc.value(url), "https://fixture.example/2/1234/info.html")
        XCTAssertEqual(engine.variable("cid"), "2")
        XCTAssertEqual(try doc.value("@js:const item=JSON.parse(result);if(item.name.match(/{{}\\}/)){item.name='encrypted'};item.name"), "正常书名")
        XCTAssertNil(try ScriptRule.parts("{{'<js>'}}"))
        XCTAssertEqual(try doc.value("{{'<js>'}}"), "<js>")
    }
    func testTrailingAndPrefixPutKeepExtractionAndUseOriginalJSONScope() throws {
        let script = try SourceScript()
        let doc = try RuleDocument.parse(Data(#"{"Id":123,"Desc":"故事简介"}"#.utf8), base: URL(string: "https://fixture.example")!, script: script)
        XCTAssertTrue(RuleComposition.isSupported("$.Desc@put:{bid:$.Id}"))
        XCTAssertEqual(try doc.value("$.Desc@put:{bid:$.Id}"), "故事简介")
        XCTAssertEqual(script.variable("bid"), "123")
        XCTAssertEqual(try doc.value("@put:{one:$.Id}$.Desc@put:{two:$.Id}"), "故事简介")
        XCTAssertEqual(script.variable("one"), "123"); XCTAssertEqual(script.variable("two"), "123")
        XCTAssertEqual(try doc.value("@js:'literal @put:{not:rule}'"), "literal @put:{not:rule}")
    }
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
    func testExtractionContinuesAfterScriptClosingTag() throws {
        let doc = try RuleDocument.parse(Data("<p>原始内容</p>".utf8), base: base)
        XCTAssertEqual(try doc.value("<js>'<a href=\"/next\">下一页</a>'</js>@href"), "/next")
        XCTAssertEqual(try doc.value("<js>({title:'故事'})</js>$.title"), "故事")
        XCTAssertEqual(try doc.elements("<js>'<div><b>A</b><b>B</b></div>'</js>b").map { try $0.value("text") }, ["A", "B"])
    }
}
