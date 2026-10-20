import Foundation
import XCTest
@testable import ReaderCore

final class DeferredSnapshotWriterTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testThousandProgressUpdatesEncodeOnlyLatestSnapshotAndKeepBackup() throws {
        let root = try directory(), file = root.appendingPathComponent("index.json"), backup = root.appendingPathComponent("backup.json")
        let writer = DeferredSnapshotWriter(destination: file, backup: backup, delay: 60)
        try writer.writeNow { Data("original".utf8) }
        for index in 0..<1000 {
            writer.schedule(encode: {
                XCTAssertEqual(index, 999, "Intermediate snapshots must never be encoded")
                return Data("progress-\(index)".utf8)
            }, failure: { XCTFail("Unexpected failure: \($0)") })
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        try writer.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "progress-999")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
    }
    func testScheduledEncodingRunsOffMainThread() async throws {
        let root = try directory(), file = root.appendingPathComponent("index.json")
        let writer = DeferredSnapshotWriter(destination: file, backup: root.appendingPathComponent("backup.json"), delay: 0.01)
        let encoded = expectation(description: "Background snapshot encoded")
        await MainActor.run {
            writer.schedule(encode: {
                XCTAssertFalse(Thread.isMainThread)
                encoded.fulfill()
                return Data("saved".utf8)
            }, failure: { XCTFail("Unexpected failure: \($0)") })
        }
        await fulfillment(of: [encoded], timeout: 3)
        try writer.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved")
    }
    func testExplicitSaveAndRestoreCannotBeOverwrittenByOldTimer() async throws {
        let root = try directory(), file = root.appendingPathComponent("index.json")
        let writer = DeferredSnapshotWriter(destination: file, backup: root.appendingPathComponent("backup.json"), delay: 0.02)
        writer.schedule(encode: { XCTFail("Stale progress encoded"); return Data() }, failure: { XCTFail("\($0)") })
        try writer.writeNow { Data("explicit".utf8) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "explicit")
        writer.schedule(encode: { XCTFail("Pre-restore progress encoded"); return Data() }, failure: { XCTFail("\($0)") })
        writer.discardPendingAndWait()
        try Data("restored".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(80))
        try writer.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "restored")
    }
    func testFailedFlushKeepsPendingSnapshotForRetry() throws {
        let root = try directory(), blocked = root.appendingPathComponent("blocked")
        try Data("not a folder".utf8).write(to: blocked)
        let file = blocked.appendingPathComponent("index.json")
        let writer = DeferredSnapshotWriter(destination: file, backup: blocked.appendingPathComponent("backup.json"), delay: 60)
        writer.schedule(encode: { Data("retry".utf8) }, failure: { _ in })
        XCTAssertThrowsError(try writer.flush())
        try FileManager.default.removeItem(at: blocked)
        try writer.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "retry")
    }
    func testDiagnosticSnapshotMatchesRulesAndReflectsEdits() async throws {
        let json = #"{"bookSourceName":"测试","bookSourceUrl":"https://example.org","searchUrl":"/search?q={{key}}","ruleSearch":{"bookList":"a","name":"text","bookUrl":"href"},"ruleToc":{"chapterList":"a","chapterName":"text","chapterUrl":"href"},"ruleContent":{"content":"body@text"}}"#
        var source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let first = try await SourceDiagnostics.analyze([source])
        XCTAssertEqual(first[source.id]?.search, source.searchIncompatibility)
        XCTAssertEqual(first[source.id]?.full, source.incompatibility)
        source.searchUrl = nil
        let edited = try await SourceDiagnostics.analyze([source])
        XCTAssertNotNil(edited[source.id]?.search)
        XCTAssertEqual(edited[source.id]?.search, source.searchIncompatibility)
    }
}
