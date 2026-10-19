import Foundation
import XCTest
@testable import ReaderCore

final class SearchPresentationTests: XCTestCase {
    private func hit(_ title: String, _ author: String, _ source: String, ms: Int = 20) -> SourceSearchHit {
        SourceSearchHit(novel: OnlineNovel(title: title, author: author, url: URL(string: "https://\(source).example/book")!, sourceID: source), sourceName: source, elapsedMilliseconds: ms)
    }
    func testAggregationKeepsDifferentAndUnknownAuthorsSeparate() {
        let input = [hit("《三国演义》", "作者：罗贯中", "one"), hit("三国演义", "罗贯中", "two"), hit("三国演义", "张三", "three"), hit("三国演义", "", "four"), hit("三国演义", "", "five")]
        let groups = BookSearchPresentation.groups(input, query: "三国演义")
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[0].variants.count, 2)
        XCTAssertEqual(groups[0].sourceCount, 2)
        XCTAssertEqual(BookSearchPresentation.groups(input, query: "三国演义", merged: false).count, 5)
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
    }
    func testExactFiltersAndRankingDoNotDiscardOtherSourceVersions() {
        let input = [hit("三国续篇", "作者乙", "one", ms: 10), hit("三国", "作者甲", "two", ms: 30), hit("另一部书", "三国", "three", ms: 5), hit("三国", "作者甲", "four", ms: 1)]
        let groups = BookSearchPresentation.groups(input, query: "三国")
        XCTAssertEqual(groups.first?.representative.novel.title, "三国")
        XCTAssertEqual(groups.first?.variants.count, 2)
        XCTAssertEqual(BookSearchPresentation.groups(input, query: "三国", field: .title, exact: true).count, 1)
        XCTAssertEqual(BookSearchPresentation.groups(input, query: "三国", field: .author, exact: true).first?.representative.novel.title, "另一部书")
        XCTAssertEqual(BookSearchPresentation.groups(input, query: "三国", sort: .speed).first?.sourceCount, 2)
        XCTAssertEqual(BookSearchPresentation.groups(input, query: "三国", sort: .arrival).first?.representative.novel.title, "三国续篇")
    }
    func testHistoryBoundsDeduplicationAndPersistence() throws {
        var history = BookSearchHistory()
        for n in 0..<40 { history.record("书\(n)") }
        XCTAssertEqual(history.keywords.count, 30)
        history.record(" ＧＡＶＩＮ "); history.record("gavin")
        XCTAssertEqual(history.keywords.first, "gavin")
        XCTAssertEqual(history.keywords.filter { BookSearchPresentation.normalized($0) == "gavin" }.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BookSearchHistory.self, from: JSONEncoder().encode(history)), history)
        history.remove("gavin"); XCTAssertFalse(history.keywords.contains("gavin"))
        history.clear(); XCTAssertTrue(history.keywords.isEmpty)
    }
    func testDeadlineDoesNotHoldOtherSourcesUntilNetworkTimeout() async throws {
        let sources = try (0..<2).map { i in try JSONDecoder().decode(BookSource.self, from: Data("{\"bookSourceName\":\"\(i)\",\"bookSourceUrl\":\"https://source\(i).example\"}".utf8)) }
        let recorder = PresentationRecorder()
        try await SourceSearch.run(requests: sources.map { SourceSearchRequest(source: $0, page: 1) }, concurrency: 2, timeoutSeconds: 0.05, search: { source, _ in
            if source.bookSourceName == "0" { try await Task.sleep(for: .seconds(20)) }
            return [OnlineNovel(title: "公版故事", url: URL(string: "https://example.org/book")!, sourceID: source.id)]
        }, onResult: { await recorder.append($0); return true })
        let values = await recorder.values
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.filter { $0.failure?.contains("超时") == true }.count, 1)
        XCTAssertEqual(values.flatMap(\.novels).count, 1)
    }
}
private actor PresentationRecorder {
    var values: [SourceSearchOutcome] = []
    func append(_ value: SourceSearchOutcome) { values.append(value) }
}
