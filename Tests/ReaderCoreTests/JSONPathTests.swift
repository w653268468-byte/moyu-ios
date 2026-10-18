import Foundation
import XCTest
@testable import ReaderCore

final class JSONPathTests: XCTestCase {
    private func value() throws -> Any {
        try JSONSerialization.jsonObject(with: Data(#"{"limit":20,"books":[{"name":"A","price":8,"free":true,"tags":["x","y"]},{"name":"B","price":25,"free":false},{"name":"C","price":15,"free":false,"note":null},{"name":"D","price":4,"free":true,"note":"中文🌸"}],"deep":{"books":[{"name":"E"}]}}"#.utf8))
    }
    private func names(_ path: String) throws -> [String] { try JSONPath.select(path, from: value()).compactMap { $0 as? String } }

    func testComparisonAndBooleanPrecedence() throws {
        XCTAssertEqual(try names("$.books[?(@.price < 20 && @.free == true)].name"), ["A", "D"])
        XCTAssertEqual(try names("$.books[?@.name == 'B' || @.price < 10 && @.free == true].name"), ["A", "B", "D"])
        XCTAssertEqual(try names("$.books[?(@.price <= $.limit && !(@.name == 'A'))].name"), ["C", "D"])
        XCTAssertTrue(JSONRule.isSupported("$.books[?(@.price < 10 || @.name == 'C')].name"))
        XCTAssertEqual(JSONPath.alternatives("$.books[?(@.price < 10 || @.name == 'C')].name||$.fallback"), ["$.books[?(@.price < 10 || @.name == 'C')].name", "$.fallback"])
    }
    func testExistenceMissingAndNullHaveDifferentMeanings() throws {
        XCTAssertEqual(try names("$.books[?@.note].name"), ["C", "D"])
        XCTAssertEqual(try names("$.books[?!@.note].name"), ["A", "B"])
        XCTAssertEqual(try names("$.books[?@.note == null].name"), ["C"])
        XCTAssertEqual(try names("$.books[?@.absent == @.missing].name"), ["A", "B", "C", "D"])
        XCTAssertEqual(try names("$.books[?@.free == 1].name"), [])
        XCTAssertEqual(try names("$.books[?@.free].name"), ["A", "B", "C", "D"], "False-valued properties still exist")
    }
    func testArraySlicesUnionAndRecursiveDescent() throws {
        XCTAssertEqual(try names("$.books[0,2,-1].name"), ["A", "C", "D"])
        XCTAssertEqual(try names("$.books[1:4:2].name"), ["B", "D"])
        XCTAssertEqual(try names("$.books[::-1].name"), ["D", "C", "B", "A"])
        XCTAssertEqual(try names("$.books[-100:100].name"), ["A", "B", "C", "D"])
        XCTAssertEqual(try names("$.books[::0].name"), [])
        XCTAssertEqual(try names("$..name"), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(try names("$.books[0]['name','missing']"), ["A"])
    }
    func testFunctionsAndQuotedSelectors() throws {
        XCTAssertEqual(try names("$.books[?length(@.tags) == 2].name"), ["A"])
        XCTAssertEqual(try names("$.books[?count(@.tags[*]) == 2].name"), ["A"])
        XCTAssertEqual(try names("$.books[?length(@.note) == 3].name"), ["D"])
        XCTAssertEqual(try names("$.books[?match(@.name,'[AB]')].name"), ["A", "B"])
        XCTAssertEqual(try names("$.books[?search(@.note,'文')].name"), ["D"])
        XCTAssertEqual(try names("$.books[?value(@.tags[0]) == 'x'].name"), ["A"])
        let object = ["a]b": "ok", "a'b": "quoted", "a\"b": "double"]
        XCTAssertEqual(try JSONPath.select("$['a]b']", from: object) as? [String], ["ok"])
        XCTAssertEqual(try JSONPath.select("$['a\\'b']", from: object) as? [String], ["quoted"])
        XCTAssertEqual(try JSONPath.select("$[\"a\\\"b\"]", from: object) as? [String], ["double"])
    }
    func testMalformedFiltersAndScriptsAreRejected() throws {
        for path in ["$.books[?(@.price < )]", "$.books[?evil(@.name)]", "$.books[?@.name == 'A'", "$.books[?count(@.name, 2)]", "$.books[(@.length-1)]"] {
            XCTAssertThrowsError(try JSONPath.select(path, from: value()), path)
            XCTAssertFalse(JSONRule.isSupported(path), path)
        }
    }
    func testRuleDocumentCanExtractWithLogicalOrFilter() throws {
        let data = try JSONSerialization.data(withJSONObject: value())
        let doc = try RuleDocument.parse(data, base: URL(string: "https://example.com")!)
        let rows = try doc.elements("$.books[?(@.free == true || @.name == 'B')]")
        XCTAssertEqual(try rows.map { try $0.value("$.name") }, ["A", "B", "D"])
        XCTAssertEqual(try doc.value("$.books[?(@.name == 'A' || @.name == 'D')].name"), "A\nD")
    }
}
