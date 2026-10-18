import Foundation
import XCTest
@testable import ReaderCore

final class ExploreTests: XCTestCase {
    func testLegadoCategoryFormatsAndHeadings() throws {
        let lines = try ExploreCategory.parse("分类\n玄幻::/sort/1/{{page}}\n都市::/sort/2/{{page}}\n玄幻::/sort/1/{{page}}")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].isHeading)
        XCTAssertFalse(lines[1].isHeading)
        let json = try ExploreCategory.parse(#"[{"title":"分类","url":"","style":{"layout_flexBasisPercent":1}},{"title":"历史","url":"/history/{{page}}"}]"#)
        XCTAssertTrue(json[0].isHeading)
        XCTAssertEqual(json[1].title, "历史")
        XCTAssertThrowsError(try ExploreCategory.parse("[broken]"))
    }
    func testFirstAndLaterPageURLAlternatives() throws {
        let base = URL(string: "https://books.example")!
        let first = try SourceRequest.make("/txt/history/<,index_{{page}}.html>", query: "", base: base)
        let second = try SourceRequest.make("/txt/history/<,index_{{page}}.html>", query: "", base: base, page: 2)
        XCTAssertEqual(first.url!.absoluteString, "https://books.example/txt/history/")
        XCTAssertEqual(second.url!.absoluteString, "https://books.example/txt/history/index_2.html")
    }
}
