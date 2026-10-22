import Foundation
import XCTest
@testable import ReaderCore

private actor ChapterGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var result: String?
    private(set) var calls = 0
    func load() async -> String {
        calls += 1
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ text: String) { result = text; continuation?.resume(returning: text); continuation = nil }
}

final class ChapterReadCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw SourceError.message("chapter cache test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testForegroundJoinsPrefetchAndSurvivesItsCancellation() async throws {
        let file = try directory().appendingPathComponent("chapter.txt"), cache = ChapterReadCache(), gate = ChapterGate()
        let prefetch = Task { try await cache.read(at: file) { await gate.load() } }
        try await wait { await cache.waiterCount(at: file) == 1 }
        let foreground = Task { try await cache.read(at: file) { await gate.load() } }
        try await wait { await cache.waiterCount(at: file) == 2 }
        prefetch.cancel()
        try await wait { await cache.waiterCount(at: file) == 1 }
        await gate.finish("准备好的第二章")
        let text = try await foreground.value
        XCTAssertEqual(text, "准备好的第二章")
        do { _ = try await prefetch.value; XCTFail("Cancelled prefetch returned") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
        let disk = try await cache.read(at: file) { throw SourceError.message("network disconnected") }
        XCTAssertEqual(disk, text)
    }
    func testClearRejectsLateResponseAndAllowsFreshRead() async throws {
        let root = try directory(), file = root.appendingPathComponent("chapter.txt"), cache = ChapterReadCache(), gate = ChapterGate()
        let old = Task { try await cache.read(at: file) { await gate.load() } }
        try await wait { await cache.waiterCount(at: file) == 1 }
        try await cache.clear(in: root)
        await gate.finish("不应写回的旧正文")
        do { _ = try await old.value; XCTFail("Stale request returned") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let fresh = try await cache.read(at: file) { "新正文" }
        XCTAssertEqual(fresh, "新正文")
    }
    func testFailedRequestCanRetryAndFailedWriteIsVisible() async throws {
        let root = try directory(), file = root.appendingPathComponent("chapter.txt"), cache = ChapterReadCache()
        do { _ = try await cache.read(at: file) { throw SourceError.message("offline") }; XCTFail("Expected failure") } catch {}
        let result = try await cache.read(at: file) { "重试正文" }; XCTAssertEqual(result, "重试正文")
        let invalid = root.appendingPathComponent("missing/chapter.txt")
        do { _ = try await cache.read(at: invalid) { "正文" }; XCTFail("Failed cache write hidden") } catch {}
    }
}
