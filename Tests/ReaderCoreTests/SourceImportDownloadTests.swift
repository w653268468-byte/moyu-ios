import Foundation
import XCTest
@testable import ReaderCore

private final class ImportDownloadFixture: URLProtocol {
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "import.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.request.url else { return }
            var headers = ["Content-Type": "application/json"]
            if url.path == "/length" { headers["Content-Length"] = "2048" }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 512))
            self.client?.urlProtocol(self, didLoad: Data(repeating: 66, count: url.path == "/overflow" ? 513 : 512))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.url?.path == "/slow" ? 2 : 0.01), execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}

final class SourceImportDownloadTests: XCTestCase {
    private func download(_ path: String, limit: Int = 1024) async throws -> (Data, URL) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImportDownloadFixture.self]
        return try await SourceImportDownload(configuration: config, limit: limit).run(URL(string: "https://import.fixture" + path)!)
    }
    func testChunkedDownloadAcceptsExactLimitAndRejectsOverflow() async throws {
        let (data, url) = try await download("/exact")
        XCTAssertEqual(data.count, 1024); XCTAssertEqual(url.path, "/exact")
        for path in ["/overflow", "/length"] {
            do { _ = try await download(path); XCTFail("Oversized collection accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("超过")) }
        }
    }
    func testCancellationFinishesWithoutWaitingForServer() async {
        let task = Task { try await download("/slow") }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import returned data") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
