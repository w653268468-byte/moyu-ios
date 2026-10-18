import Foundation
import XCTest
@testable import ReaderCore

final class SourceScriptTests: XCTestCase {
    let base = URL(string: "https://books.example/book/1")!
    func testModernJavaScriptAndStructuredOutput() throws {
        let engine = try SourceScript()
        let value = try engine.evaluate("JSON.parse(result).books.filter(b => b.free).map(({name}) => name)", result: #"{"books":[{"name":"三国","free":true},{"name":"Other","free":false}]}"#, baseURL: base)
        XCTAssertEqual(value as? [String], ["三国"])
    }
    func testHTMLAndJavaLikeCollections() throws {
        let engine = try SourceScript()
        let html = "<div class='book'><a href='/a'>三国</a></div><div class='book'><a href='/b'>水浒</a></div>"
        let value = try engine.evaluate("java.getElements('.book').toArray().map(o => o.select('a').first().text())", result: html, baseURL: base)
        XCTAssertEqual(value as? [String], ["三国", "水浒"])
        XCTAssertEqual(try engine.evaluate("java.getString('a@href')", result: html, baseURL: base) as? String, "/a\n/b")
        XCTAssertEqual(try engine.evaluate("org.jsoup.Jsoup.parse(result).select('a').last().attr('href')", result: html, baseURL: base) as? String, "/b")
    }
    func testEncodingHashesAndVariables() throws {
        let engine = try SourceScript()
        XCTAssertEqual(try engine.evaluate("java.base64Decode(java.base64Encode(result))", result: "中文🌸", baseURL: base) as? String, "中文🌸")
        XCTAssertEqual(try engine.evaluate("java.md5Encode(result)", result: "abc", baseURL: base) as? String, "900150983cd24fb0d6963f7d28e17f72")
        _ = try engine.evaluate("java.put('chapter', '第一章')", result: "", baseURL: base)
        XCTAssertEqual(try engine.evaluate("java.get('chapter')", result: "", baseURL: base) as? String, "第一章")
        XCTAssertEqual(try engine.evaluate("java.resolve('../toc')", result: "", baseURL: base) as? String, "https://books.example/toc")
    }
    func testRuleDocumentPipelinesPreserveElementsAndScope() throws {
        let doc = try RuleDocument.parse(Data("<div class='book'><a href='/a'>三国</a></div><div class='book'><a href='/b'>水浒</a></div>".utf8), base: base)
        let rows = try doc.elements(".book<js>result.toArray().slice(0,1)</js>")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].value("a@text@js:result + '演义'"), "三国演义")
        XCTAssertEqual(try rows[0].value("a@href"), "/a")
        _ = try doc.value("@js:java.put('shared','kept')")
        XCTAssertEqual(try rows[0].value("@js:java.get('shared')"), "kept")
        let json = try RuleDocument.parse(Data(#"{"books":[{"name":"A"},{"name":"B"}]}"#.utf8), base: base)
        XCTAssertEqual(try json.value("$.books@js:result.map(b => b.name).join(',')"), "A,B")
    }
    func testInfiniteLoopIsInterruptedAndUnknownBridgeIsVisible() throws {
        let engine = try SourceScript()
        let began = Date()
        XCTAssertThrowsError(try engine.evaluate("while (true) {}", result: "", baseURL: base, timeout: 0.05)) { error in
            XCTAssertTrue(error.localizedDescription.contains("时间限制"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertThrowsError(try engine.evaluate("java.unimplementedInterface()", result: "", baseURL: base)) { error in
            XCTAssertTrue(error.localizedDescription.contains("java.unimplementedInterface"))
        }
        XCTAssertEqual(try engine.evaluate("[typeof std, typeof os, typeof Worker].join(',')", result: "", baseURL: base) as? String, "undefined,undefined,undefined")
    }
}
