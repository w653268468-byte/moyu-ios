import Foundation
import CoreText
import CoreGraphics
import XCTest
@testable import ReaderCore

final class PaginationTests: XCTestCase {
    func testRangesCoverChineseEmojiAndReflowWithoutGaps() throws {
        let content = String(repeating: "春天到了，河边的花开了。👨‍👩‍👧‍👦🌸 Reading Gavin.\n", count: 100)
        func layout(_ fontSize: CGFloat, _ width: CGFloat) throws -> [NSRange] {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let text = NSAttributedString(string: content, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return try TextPagination.ranges(text, size: CGSize(width: width, height: 500))
        }
        let normal = try layout(20, 320)
        XCTAssertGreaterThan(normal.count, 1)
        var end = 0
        for range in normal {
            XCTAssertEqual(range.location, end)
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertNotNil(Range(range, in: content), "A page must not split composed characters")
            end = NSMaxRange(range)
        }
        XCTAssertEqual(end, (content as NSString).length)
        XCTAssertGreaterThan(try layout(32, 320).count, normal.count)
        XCTAssertGreaterThan(try layout(20, 180).count, normal.count)
    }
    func testParagraphNormalizationIsStableForSavedOffsets() {
        let text = "  第一段\r\n\r\n   第二段  \n\n"
        XCTAssertEqual(TextPagination.readingText(text), "第一段\n第二段")
        XCTAssertEqual(TextPagination.readingText(TextPagination.readingText(text)), TextPagination.readingText(text))
    }
    func testEmptyTextAndInvalidViewport() throws {
        XCTAssertEqual(try TextPagination.ranges(NSAttributedString(string: ""), size: CGSize(width: 320, height: 500)), [NSRange(location: 0, length: 0)])
        XCTAssertThrowsError(try TextPagination.ranges(NSAttributedString(string: "a"), size: CGSize(width: 10, height: 500)))
    }
}
