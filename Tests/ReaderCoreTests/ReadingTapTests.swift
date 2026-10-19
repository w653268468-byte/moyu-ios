import XCTest
@testable import ReaderCore

final class ReadingTapTests: XCTestCase {
    func testFullViewportIncludesEdgesMarginsAndCenter() {
        for x in [0.0, 1, 120, 200, 399, 400] {
            for y in [0.0, 1, 200, 400, 799, 800] {
                XCTAssertEqual(ReadingTapMap.allNext.action(x: x, y: y, width: 400, height: 800), .next)
            }
        }
    }
    func testCustomZonesPersistAndInvalidSettingsRecover() {
        var map = ReadingTapMap.classic; map.actions[0] = .none; map.actions[7] = .previous
        XCTAssertEqual(ReadingTapMap(stored: map.stored), map)
        for row in 0..<3 { for column in 0..<3 {
            XCTAssertEqual(map.action(x: Double(column * 100 + 50), y: Double(row * 100 + 50), width: 300, height: 300), map.actions[row * 3 + column])
        } }
        XCTAssertEqual(ReadingTapMap(stored: "next,bad,next"), .classic)
        XCTAssertEqual(map.action(x: .nan, y: 1, width: 300, height: 300), .none)
    }
}
