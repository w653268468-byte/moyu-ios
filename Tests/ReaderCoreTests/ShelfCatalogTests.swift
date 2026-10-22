import XCTest
@testable import ReaderCore

final class ShelfCatalogTests: XCTestCase {
    private func book(_ count: Int) -> OnlineNovel {
        var book = OnlineNovel(title: "追更", url: URL(string: "https://example.com/book")!, sourceID: "example")
        book.chapters = (0..<count).map { OnlineChapter(title: "第\($0 + 1)章", url: URL(string: "https://example.com/\($0)")!) }
        return book
    }
    func testRefreshFindsNewChaptersAndPreservesReadingPosition() {
        var old = book(3); old.chapterIndex = 1; old.textOffset = 37; old.scrollFraction = 0.25
        let date = Date(timeIntervalSince1970: 100)
        let fresh = book(4).refreshedCatalog(from: old, at: date)
        XCTAssertEqual(fresh.chapterIndex, 1); XCTAssertEqual(fresh.textOffset, 37)
        XCTAssertEqual(fresh.scrollFraction, 0.25)
        XCTAssertEqual(fresh.lastChapter, "第4章")
        XCTAssertEqual(fresh.unreadChapterIDs, ["https://example.com/3"])
        XCTAssertEqual(fresh.catalogUpdatedAt, date)
        XCTAssertEqual(fresh.catalogCheckedAt, date)
        let again = book(4).refreshedCatalog(from: fresh, at: date.addingTimeInterval(30))
        XCTAssertEqual(again.unreadChapterIDs, fresh.unreadChapterIDs)
        XCTAssertEqual(again.catalogUpdatedAt, date, "Checking an unchanged catalog must not falsely promote the book as newly updated")
        let shortened = book(3).refreshedCatalog(from: again, at: date.addingTimeInterval(60))
        XCTAssertEqual(shortened.unreadChapterIDs, [])
    }
    func testFirstCatalogDoesNotMarkAllChaptersAsNewAndOldBackupsDecode() throws {
        let fresh = book(5).refreshedCatalog(from: book(0), at: Date())
        XCTAssertEqual(fresh.unreadChapterIDs, [])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book(3))) as! [String: Any]
        XCTAssertNil(object["catalogCheckedAt"])
        let decoded = try JSONDecoder().decode(OnlineNovel.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.unreadChapterIDs)
        XCTAssertEqual(decoded.chapters.count, 3)
    }
}
