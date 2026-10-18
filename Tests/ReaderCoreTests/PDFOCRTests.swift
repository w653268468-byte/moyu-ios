#if canImport(PDFKit) && canImport(Vision)
import Foundation
import PDFKit
import CoreText
import CoreGraphics
import XCTest
@testable import ReaderCore

final class PDFOCRTests: XCTestCase {
    func testRasterOnlyPDFGetsSearchableText() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 900, height: 1200, bitsPerComponent: 8, bytesPerRow: 3600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let line = NSAttributedString(string: "Gavin reader OCR", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        bitmap.textPosition = CGPoint(x: 60, y: 900)
        CTLineDraw(CTLineCreateWithAttributedString(line), bitmap)
        let image = try XCTUnwrap(bitmap.makeImage())
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let pdfContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(image, in: box)
        pdfContext.endPDFPage(); pdfContext.closePDF()
        let data = bytes as Data
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let book = try LocalBookImporter.parse(data, filename: "scanned.pdf")
        XCTAssertTrue(book.pages[0].text.localizedCaseInsensitiveContains("Gavin"), book.pages[0].text)
        XCTAssertTrue(book.pages[0].text.localizedCaseInsensitiveContains("reader"), book.pages[0].text)
        XCTAssertFalse(book.search("reader").isEmpty)
    }
}
#endif
