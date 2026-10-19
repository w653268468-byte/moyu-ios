import Foundation
import XCTest
@testable import ReaderCore

private actor SearchProbe {
    var active = 0, maximum = 0, started = 0
    var outcomes: [SourceSearchOutcome] = []
    func begin() { active += 1; started += 1; maximum = max(maximum, active) }
    func end() { active -= 1 }
    func accept(_ result: SourceSearchOutcome) { outcomes.append(result) }
    func snapshot() -> (Int, Int, Int) { (maximum, started, outcomes.count) }
}

final class SourceSearchTests: XCTestCase {
    private func source(_ index: Int) throws -> BookSource {
        try JSONDecoder().decode(BookSource.self, from: Data("{\"bookSourceName\":\"Source \(index)\",\"bookSourceUrl\":\"https://source\(index).example\"}".utf8))
    }
    private func book(source: String, path: String = "one") -> OnlineNovel {
        OnlineNovel(title: "公版故事", url: URL(string: "https://shared.example/\(path)")!, sourceID: source)
    }
    func testPagingKeepsSourcesDistinctAndRetriesFailedPage() throws {
        var state = SourceSearchState()
        let a = try source(1), b = try source(2)
        state.receive(SourceSearchOutcome(sourceID: a.id, sourceName: a.bookSourceName, page: 1, novels: [book(source: a.id)]))
        state.receive(SourceSearchOutcome(sourceID: b.id, sourceName: b.bookSourceName, page: 1, novels: [book(source: b.id)]))
        XCTAssertEqual(state.hits.count, 2)
        XCTAssertEqual(Set(state.hits.map(\.id)).count, 2)
        state.receive(SourceSearchOutcome(sourceID: a.id, sourceName: a.bookSourceName, page: 2, novels: [], failure: "timeout"))
        XCTAssertEqual(state.nextPages[a.id], 2)
        XCTAssertNotNil(state.failures[a.id])
        state.receive(SourceSearchOutcome(sourceID: a.id, sourceName: a.bookSourceName, page: 2, novels: [book(source: a.id, path: "two")]))
        XCTAssertNil(state.failures[a.id])
        XCTAssertEqual(state.nextPages[a.id], 3)
        state.receive(SourceSearchOutcome(sourceID: a.id, sourceName: a.bookSourceName, page: 3, novels: [book(source: a.id), book(source: a.id, path: "two")]))
        XCTAssertTrue(state.exhausted.contains(a.id), "A site repeating a previous page must stop pagination")
        XCTAssertEqual(state.hits.count, 3)
    }
    func testConcurrencyBoundAndPartialFailure() async throws {
        let probe = SearchProbe()
        let jobs = try (0..<7).map { SourceSearchRequest(source: try source($0), page: 1) }
        try await SourceSearch.run(requests: jobs, concurrency: 2, search: { source, _ in
            await probe.begin()
            try await Task.sleep(for: .milliseconds(20))
            await probe.end()
            if source.id.contains("source2.") { throw SourceError.message("fixture failure") }
            return [OnlineNovel(title: "公版故事", url: URL(string: "https://shared.example/one")!, sourceID: source.id)]
        }, onResult: { result in await probe.accept(result); return true })
        let (maximum, started, received) = await probe.snapshot()
        XCTAssertEqual(maximum, 2); XCTAssertEqual(started, 7); XCTAssertEqual(received, 7)
        let outcomes = await probe.outcomes
        XCTAssertEqual(outcomes.filter { $0.failure != nil }.count, 1)
        XCTAssertEqual(outcomes.flatMap(\.novels).count, 6)
    }
    func testStoppingDeliveryCancelsUnstartedSources() async throws {
        let probe = SearchProbe()
        let jobs = try (0..<30).map { SourceSearchRequest(source: try source($0), page: 1) }
        try await SourceSearch.run(requests: jobs, concurrency: 2, search: { _, _ in
            await probe.begin()
            try await Task.sleep(for: .milliseconds(20))
            return []
        }, onResult: { result in await probe.accept(result); return false })
        let (_, started, received) = await probe.snapshot()
        XCTAssertLessThanOrEqual(started, 2); XCTAssertEqual(received, 1)
    }
}
