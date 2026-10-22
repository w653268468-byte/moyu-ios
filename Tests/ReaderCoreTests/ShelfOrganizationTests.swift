import XCTest
@testable import ReaderCore

final class ShelfOrganizationTests: XCTestCase {
    func testMultiGroupRenameDeletionAndPinsRemainIndependent() throws {
        var shelf = ShelfOrganization()
        try shelf.addGroup(" 追更 "); try shelf.addGroup("收藏")
        let first = shelf.groups[0].id, second = shelf.groups[1].id
        shelf.setMembership("novel", group: first, enabled: true)
        shelf.setMembership("novel", group: second, enabled: true)
        shelf.pinned.insert("novel")
        XCTAssertTrue(shelf.contains("novel", in: first))
        XCTAssertFalse(shelf.contains("novel", in: "ungrouped"))
        XCTAssertTrue(shelf.contains("another", in: "ungrouped"))
        try shelf.renameGroup(first, name: "连载")
        XCTAssertTrue(shelf.contains("novel", in: first), "Renaming must not detach books")
        shelf.removeGroup(first)
        XCTAssertTrue(shelf.contains("novel", in: second))
        XCTAssertTrue(shelf.pinned.contains("novel"))
        shelf.removeGroup(second)
        XCTAssertTrue(shelf.contains("novel", in: "ungrouped"))
        XCTAssertEqual(try JSONDecoder().decode(ShelfOrganization.self, from: JSONEncoder().encode(shelf)), shelf)
    }
    func testInvalidAndDuplicateNamesDoNotMutateGroups() throws {
        var shelf = ShelfOrganization(); try shelf.addGroup("Reading")
        XCTAssertThrowsError(try shelf.addGroup(" reading "))
        XCTAssertThrowsError(try shelf.addGroup(" "))
        XCTAssertThrowsError(try shelf.addGroup(String(repeating: "长", count: 41)))
        XCTAssertEqual(shelf.groups.count, 1)
        shelf.setMembership("book", group: "missing", enabled: true)
        XCTAssertTrue(shelf.contains("book", in: "ungrouped"))
    }
}
