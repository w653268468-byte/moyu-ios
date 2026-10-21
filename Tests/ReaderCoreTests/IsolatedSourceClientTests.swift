import Foundation
import XCTest
@testable import ReaderCore

private actor IsolatedChapterGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func render(_ request: URLRequest) async throws -> (Data, URL) {
        guard let url = request.url else { throw SourceError.message("Missing fixture URL") }
        if url.path == "/first" {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return (Data("<p>fixture</p>".utf8), url)
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class IsolatedSourceClientTests: XCTestCase {
    func testDownloadWorkersKeepChapterGlobalsIndependentWhileRequestsOverlap() async throws {
        let gate = IsolatedChapterGate()
        let parent = SourceClient(webRenderer: { request, _ in try await gate.render(request) })
        let firstWorker = await parent.isolatedWorker(), secondWorker = await parent.isolatedWorker()
        let source = try JSONDecoder().decode(BookSource.self, from: Data(##"{"bookSourceName":"isolated","bookSourceUrl":"https://isolated.example","ruleContent":{"content":"@js:chapter.title"}}"##.utf8))
        func chapter(_ path: String, _ title: String) -> OnlineChapter {
            let url = URL(string: "https://isolated.example/" + path)!
            return OnlineChapter(title: title, url: url, requestTemplate: url.absoluteString + ",{\"webView\":true}")
        }
        let first = Task { try await firstWorker.chapter(chapter("first", "第一章"), source: source) }
        defer { first.cancel(); Task { await gate.release() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.started) {
            guard ContinuousClock.now < deadline else { throw SourceError.message("First worker did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = try await secondWorker.chapter(chapter("second", "第二章"), source: source)
        await gate.release()
        let original = try await first.value
        XCTAssertEqual(second, "第二章")
        XCTAssertEqual(original, "第一章", "A later request must not replace the earlier request's chapter JS global")
    }
}
