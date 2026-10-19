import Foundation
import XCTest
@testable import ReaderCore

private final class DAVFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dav.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("reader:secret".utf8).base64EncodedString()
        let creating = url.path.contains("/new/")
        var status = authenticated ? 200 : 401
        if authenticated {
            if request.httpMethod == "GET" { status = creating ? 404 : 200 }
            else if url.path.contains("/stale/") { status = 412 }
            else if creating { status = request.value(forHTTPHeaderField: "If-None-Match") == "*" ? 201 : 412 }
            else { status = request.value(forHTTPHeaderField: "If-Match") == "\"v1\"" ? 204 : 412 }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag":"\"v1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "GET" && status == 200 { client?.urlProtocol(self, didLoad: Data("fixture-backup".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WebDAVTests: XCTestCase {
    private func client(_ path: String, password: String = "secret") throws -> WebDAVClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DAVFixture.self]
        return try WebDAVClient(directory: "https://dav.example/\(path)/", username: "reader", password: password, configuration: configuration)
    }
    func testConditionalCreationAndVersionedReplacement() async throws {
        let new = try client("new")
        let missing = try await new.read(); XCTAssertNil(missing)
        try await new.write(Data("new".utf8), replacing: missing)
        let existing = try client("existing")
        let snapshot = try await existing.read()
        XCTAssertEqual(snapshot?.etag, "\"v1\"")
        XCTAssertEqual(snapshot?.data, Data("fixture-backup".utf8))
        try await existing.write(Data("updated".utf8), replacing: snapshot)
        do {
            try await client("stale").write(Data(), replacing: snapshot)
            XCTFail("Concurrent cloud changes must never be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("其他设备更新")) }
        do {
            try await existing.write(Data(), replacing: WebDAVSnapshot(data: Data(), etag: "W/\"v1\""))
            XCTFail("Weak validators cannot protect replacement")
        } catch { XCTAssertTrue(error.localizedDescription.contains("强 ETag")) }
    }
    func testAuthenticationAndEndpointValidation() async throws {
        XCTAssertThrowsError(try WebDAVClient(directory: "http://dav.example", username: "reader", password: "secret"))
        XCTAssertThrowsError(try WebDAVClient(directory: "https://user:secret@dav.example/", username: "reader", password: "secret"))
        do { _ = try await client("existing", password: "wrong").read(); XCTFail("Authentication must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("账号")) }
    }
    func testThreeWaySyncDecisionPreservesConflictingChanges() {
        XCTAssertEqual(SyncDecision.compare(local: "a", remote: "a", baseline: nil), .unchanged)
        XCTAssertEqual(SyncDecision.compare(local: "a", remote: nil, baseline: nil), .upload)
        XCTAssertEqual(SyncDecision.compare(local: "a", remote: "b", baseline: nil), .conflict)
        XCTAssertEqual(SyncDecision.compare(local: "a", remote: "b", baseline: "a"), .download)
        XCTAssertEqual(SyncDecision.compare(local: "b", remote: "a", baseline: "a"), .upload)
        XCTAssertEqual(SyncDecision.compare(local: "b", remote: "c", baseline: "a"), .conflict)
        XCTAssertEqual(SyncDecision.compare(local: "a", remote: nil, baseline: "a"), .conflict)
    }
}
