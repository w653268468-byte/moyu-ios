import Foundation
import XCTest
@testable import ReaderCore

final class SourceHealthTests: XCTestCase {
    private func makeSource(_ name: String) throws -> BookSource {
        try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: ["bookSourceName": name, "bookSourceUrl": "https://\(name).example", "searchUrl": "/search?key={{key}}", "ruleSearch": ["bookList": ".book", "name": "text", "bookUrl": "href"]]))
    }
    func testRepeatedTimeoutsAreSkippedButRecoverAfterCooldown() throws {
        let bad = try makeSource("bad"), unknown = try makeSource("unknown"), fast = try makeSource("fast"), slow = try makeSource("slow")
        let now = Date(timeIntervalSince1970: 10000); var health = SourceHealthLedger()
        health.receive(bad, failure: "书源搜索超时", now: now)
        health.receive(bad, failure: "书源搜索超时", now: now)
        health.receive(fast, failure: nil, latency: 20, hasResults: true, now: now)
        health.receive(slow, failure: nil, latency: 900, hasResults: true, now: now)
        let plan = health.ordered([bad, unknown, slow, fast], now: now)
        XCTAssertEqual(plan.active.map(\.id), [fast.id, slow.id, unknown.id]); XCTAssertEqual(plan.avoided.map(\.id), [bad.id])
        XCTAssertTrue(health.ordered([bad], now: now.addingTimeInterval(301)).avoided.isEmpty)
        XCTAssertFalse(health.record(for: bad)!.removable)
        health.receive(bad, failure: nil, latency: 12, hasResults: true, now: now)
        XCTAssertEqual(health.record(for: bad)?.failures, 0)
    }
    func testOnlyTwoVerifiedGoneEndpointsAreCleanupCandidates() throws {
        let gone = try makeSource("gone"), timeout = try makeSource("timeout"), login = try makeSource("login"), denied = try makeSource("denied")
        var health = SourceHealthLedger()
        for _ in 0..<3 {
            health.receive(timeout, failure: "超时 -1001", verifiedProbe: true)
            health.receive(login, failure: "请登录后验证", verifiedProbe: true)
            health.receive(denied, failure: "HTTP 403", verifiedProbe: true)
            health.receive(gone, failure: "HTTP 404", verifiedProbe: false)
        }
        XCTAssertFalse(health.record(for: gone)!.removable)
        health.receive(gone, failure: "网站返回错误 HTTP 404", verifiedProbe: true)
        XCTAssertFalse(health.record(for: gone)!.removable)
        health.receive(gone, failure: "网站返回错误 HTTP 410", verifiedProbe: true)
        XCTAssertTrue(health.record(for: gone)!.removable)
        for item in [timeout, login, denied] { XCTAssertFalse(health.record(for: item)!.removable) }
        var protected = gone; protected.header = #"{"Authorization":"Bearer configured"}"#
        for _ in 0..<2 { health.receive(protected, failure: "网站返回错误 HTTP 404", verifiedProbe: true) }
        XCTAssertFalse(health.record(for: protected)!.removable)
        XCTAssertEqual(health.record(for: protected)?.kind, .login)
        XCTAssertNotEqual(SourceFailureKind.classify("JavaScript 执行失败: HTTP 404"), .endpointGone)
        health.receive(gone, failure: nil, hasResults: false)
        XCTAssertFalse(health.record(for: gone)!.removable)
    }
    func testChangedRulesInvalidateOldFailuresAndRenamingDoesNot() throws {
        var source = try makeSource("rules"), health = SourceHealthLedger()
        health.receive(source, failure: "HTTP 404", verifiedProbe: true); health.receive(source, failure: "HTTP 404", verifiedProbe: true)
        source.bookSourceName = "重命名"; source.bookSourceGroup = "分组"; source.enabled = false
        XCTAssertTrue(health.record(for: source)!.removable)
        source.searchUrl = "/new-search?key={{key}}"
        XCTAssertNil(health.record(for: source))
        XCTAssertEqual(health.ordered([source]).active.count, 1)
    }
    func testStateRoundTripAndNoResultsDoNotBecomeFailures() throws {
        let source = try makeSource("empty"); var health = SourceHealthLedger()
        health.receive(source, failure: nil, latency: 15)
        let restored = try JSONDecoder().decode(SourceHealthLedger.self, from: JSONEncoder().encode(health))
        XCTAssertEqual(restored.record(for: source)?.failures, 0)
        XCTAssertFalse(restored.record(for: source)!.removable)
        XCTAssertFalse(restored.record(for: source)!.hasResults)
    }
}
