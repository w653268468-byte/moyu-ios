import Foundation
import XCTest
@testable import ReaderCore

final class MobiTests: XCTestCase {
    func testMalformedInputIsRejectedWithoutAccessingOtherFiles() {
        XCTAssertThrowsError(try MobiConverter.epub(Data()))
        XCTAssertThrowsError(try MobiConverter.epub(Data(repeating: 0, count: 100)))
    }
    func testRealPalmDOCUncompressedHuffCDICAndKF8WithImages() throws {
        guard ProcessInfo.processInfo.environment["GAVIN_MOBI_FIXTURES"] == "1" else { throw XCTSkip("Download pinned upstream fixtures with scripts/fetch_mobi_fixtures.py") }
        for name in ["sample-cp1252.mobi", "sample-ncx.mobi", "sample-unicode-huffdic.mobi", "sample-unicode-uncompressed.mobi", "sample-obfuscated-fonts.mobi"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/mobi-fixtures/" + name))
            let converted = try MobiConverter.epub(data)
            let publication = try EPUBPublication.load(converted)
            XCTAssertFalse(publication.chapters.isEmpty, name)
            XCTAssertFalse(publication.navigation.isEmpty, name)
            let document = try LocalBookImporter.parse(converted, filename: "converted.epub")
            XCTAssertGreaterThan(document.wordCount, 0, name)
            if name == "sample-cp1252.mobi" {
                XCTAssertTrue(publication.resources.keys.contains { ["jpg", "jpeg", "png", "gif"].contains(($0 as NSString).pathExtension) }, "MOBI images must survive conversion")
            }
            if name == "sample-obfuscated-fonts.mobi" {
                XCTAssertTrue(publication.resources.keys.contains { ["ttf", "otf"].contains(($0 as NSString).pathExtension) }, "KF8 fonts must survive conversion")
            }
        }
    }
}
