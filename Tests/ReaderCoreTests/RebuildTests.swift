import Foundation
import XCTest
import ZIPFoundation
@testable import ReaderCore

final class RebuildTests: XCTestCase {
    func testJSONListsAndRelativeFields() throws {
        let data = Data(#"{"data":{"books":[{"name":"三国","url":"/b/1"},{"name":"水浒","url":"/b/2"}]}}"#.utf8)
        let doc = try RuleDocument.parse(data, base: URL(string: "https://books.example")!)
        let books = try doc.elements("$.data.books[*]")
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(try books[0].value("name"), "三国")
        XCTAssertEqual(try books[1].value("$.url"), "/b/2")
        XCTAssertEqual(try doc.value("$.data.books[-1].name"), "水浒")
        XCTAssertEqual(try doc.value("$.missing||data.books[0].name"), "三国")
        XCTAssertFalse(JSONRule.isSupported("$.data[?(@.vip)]"))
        XCTAssertFalse(JSONRule.isSupported("$.data@js:result"))
    }

    func testFormPOSTAndGETTemplates() throws {
        let base = URL(string: "https://books.example")!
        let template = #"/search,{"method":"POST","body":"key={{key}}&page={{page}}"}"#
        let request = try SourceRequest.make(template, query: "山海 &", base: base)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://books.example/search")
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "key=%E5%B1%B1%E6%B5%B7%20%26&page=1")
        let get = try SourceRequest.make("/find?q={{key}}", query: "A&B", base: base)
        XCTAssertEqual(get.url?.query, "q=A%26B")
        XCTAssertThrowsError(try SourceRequest.make(#"/s,{"method":"POST","charset":"gbk"}"#, query: "测试", base: base))
    }

    func testJSONPOSTPreservesQuotedQuery() throws {
        let template = #"/search,{"method":"POST","body":{"key":"{{key}}","page":1}}"#
        let request = try SourceRequest.make(template, query: "x\"y", base: URL(string: "https://books.example")!)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["key"] as? String, "x\"y")
    }

    func testSourceExportPreservesUnknownLegadoFields() throws {
        let json = #"{"bookSourceName":"测试","bookSourceUrl":"https://books.example","jsLib":"keep me","custom":{"a":1},"enabled":false}"#
        let sources = try SourceImport.parse(Data(json.utf8)).sources
        let exported = try JSONSerialization.jsonObject(with: SourceImport.export(sources)) as! [[String: Any]]
        XCTAssertEqual(exported[0]["jsLib"] as? String, "keep me")
        XCTAssertEqual(exported[0]["enabled"] as? Bool, false)
        XCTAssertNil(exported[0]["originalJSON"])
    }

    private func archive(_ entries: [String: String]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, string) in entries {
            let data = Data(string.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return archive.data!
    }

    func testEPUBUsesSpineOrderAndNestedPaths() throws {
        let data = try archive([
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='OPS/package.opf'/></rootfiles></container>",
            "OPS/package.opf": "<package><manifest><item id='a' href='text/a.xhtml' media-type='application/xhtml+xml'/><item id='b' href='text/b.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='b'/><itemref idref='a'/></spine></package>",
            "OPS/text/a.xhtml": "<html><body><h1>第二节</h1><p>后来的事。</p></body></html>",
            "OPS/text/b.xhtml": "<html><body><h1>第一节</h1><p>先发生的事。</p><script>secret()</script></body></html>"
        ])
        let book = try LocalBookImporter.parse(data, filename: "test.epub")
        XCTAssertEqual(book.chapters.map(\.title), ["第一节", "第二节"])
        XCTAssertTrue(book.pages[0].text.contains("先发生的事"))
        XCTAssertFalse(book.pages[0].text.contains("secret()"))
        XCTAssertEqual(book.pages.last?.chapter, 1)
    }

    func testDOCXTextRunsAreJoinedWithinParagraphs() throws {
        let data = try archive(["word/document.xml": "<w:document xmlns:w='test'><w:body><w:p><w:r><w:t>第一</w:t></w:r><w:r><w:t>段</w:t></w:r></w:p><w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>"])
        let book = try LocalBookImporter.parse(data, filename: "test.docx")
        XCTAssertTrue(book.pages[0].text.contains("第一段\n\n第二段"))
    }

    func testHTMLImportAndUnsupportedFormats() throws {
        let book = try LocalBookImporter.parse(Data("<p>山海</p><p>来信</p><style>bad</style>".utf8), filename: "test.html")
        XCTAssertTrue(book.pages[0].text.contains("山海\n\n来信"))
        XCTAssertFalse(book.pages[0].text.contains("bad"))
        XCTAssertThrowsError(try LocalBookImporter.parse(Data(), filename: "test.azw3"))
        XCTAssertThrowsError(try LocalBookImporter.parse(Data("not a zip".utf8), filename: "broken.epub"))
    }
}
