import Foundation
import XCTest
@testable import ReaderCore

final class SourceCookieTests: XCTestCase {
    private func cookie(_ domain: String, path: String = "/", secure: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: "gavin_test", .value: "session"]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }
    func testDomainBoundariesRejectUnrelatedHosts() {
        let cookie = cookie(".example.com")
        XCTAssertTrue(SourceCookies.belongs(cookie, to: URL(string: "https://example.com")!))
        XCTAssertTrue(SourceCookies.belongs(cookie, to: URL(string: "https://read.example.com")!))
        XCTAssertFalse(SourceCookies.belongs(cookie, to: URL(string: "https://badexample.com")!))
        XCTAssertFalse(SourceCookies.belongs(cookie, to: URL(string: "https://example.com.evil.test")!))
        XCTAssertFalse(SourceCookies.belongs(cookie, to: URL(string: "file:///example.com")!))
    }
    func testImportAndClearCookiesRespectOriginAndPaths() async {
        let client = SourceClient()
        let origin = URL(string: "https://reader.example.com/private/chapter")!
        await client.replaceCookies([cookie("reader.example.com", path: "/private"), cookie("unrelated.test")], for: origin)
        let matching = await client.cookies(for: origin)
        XCTAssertEqual(matching.map(\.name), ["gavin_test"])
        let otherPath = await client.cookies(for: URL(string: "https://reader.example.com/public")!)
        XCTAssertTrue(otherPath.isEmpty)
        let foreign = await client.cookies(for: URL(string: "https://unrelated.test")!)
        XCTAssertTrue(foreign.isEmpty)
        await client.replaceCookies([], for: origin)
        let cleared = await client.cookies(for: origin)
        XCTAssertTrue(cleared.isEmpty)
    }
}
