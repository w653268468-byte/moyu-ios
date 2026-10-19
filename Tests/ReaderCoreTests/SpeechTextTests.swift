import Foundation
import XCTest
@testable import ReaderCore

final class SpeechTextTests: XCTestCase {
    func testLongChapterChunksKeepUnicodeAndExactOffsets() {
        let text = String(repeating: "花开🌸，这是连续听书和恢复位置的测试。\n", count: 500)
        let chunks = SpeechText.chunks(text, maximumCharacters: 300)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertEqual(chunks.map(\.text).joined(), TextPagination.readingText(text))
        var offset = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.utf16Offset, offset)
            XCTAssertLessThanOrEqual(chunk.text.count, 300)
            offset += chunk.text.utf16.count
        }
        let boundary = SpeechText.chunks("a🌸花", startingAt: 2)
        XCTAssertEqual(boundary.first?.utf16Offset, 1)
        XCTAssertEqual(boundary.first?.text, "🌸花")
        XCTAssertTrue(SpeechText.chunks(text, startingAt: Int.max).isEmpty)
    }
}
