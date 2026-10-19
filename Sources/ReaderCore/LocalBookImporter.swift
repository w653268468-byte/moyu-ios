import Foundation
import SwiftSoup
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(PDFKit)
import PDFKit
#endif

public enum LocalBookImporter {
    public static let maximumFileBytes = 100 * 1024 * 1024
    public static let extensions = ["txt", "epub", "pdf", "md", "markdown", "html", "htm", "xhtml", "rtf", "docx"] + MobiConverter.extensions

    public static func parse(_ data: Data, filename: String, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> BookDocument {
        guard data.count <= maximumFileBytes else { throw SourceError.message("单本文件不能超过 100 MB。") }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown": return try TextParser.parse(TextParser.decode(data))
        case "html", "htm", "xhtml": return try TextParser.parse(htmlText(data))
        case "epub": return try epub(data)
        case "mobi", "azw", "azw3", "prc", "pdb": return try epub(MobiConverter.epub(data))
        case "docx":
            let archive = try Archive(data: data, accessMode: .read)
            let xml = try read("word/document.xml", archive: archive)
            let document = try XMLBookNode.parse(xml)
            let paragraphs = document.descendants("p").map { $0.descendants("t").map(\.text).joined() }
            return try TextParser.parse(paragraphs.joined(separator: "\n\n"))
        case "pdf":
            #if canImport(PDFKit)
            guard let pdf = PDFDocument(data: data) else { throw SourceError.message("PDF 损坏或无法识别。") }
            guard !pdf.isLocked else { throw SourceError.message("PDF 已加密，请先用你自己的密码解锁后导入。") }
            guard pdf.pageCount <= 10000 else { throw SourceError.message("PDF 超过 10000 页。") }
            var pages: [ReadingPage] = []
            var chapters: [Chapter] = []
            var total = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { throw SourceError.message("PDF 第 \(index + 1) 页无法读取。") }
                var text = page.string ?? ""
                #if canImport(Vision)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = try autoreleasepool { try PDFTextRecognizer.recognize(page) }
                }
                #endif
                progress?(index + 1, pdf.pageCount)
                total += text.utf8.count
                guard total <= 40 * 1024 * 1024 else { throw SourceError.message("PDF 文字内容过大。") }
                chapters.append(Chapter(id: index, title: "第 \(index + 1) 页", firstPage: pages.count))
                pages.append(ReadingPage(id: pages.count, chapter: index, text: text.isEmpty ? "本页未识别到文字（可能是空白页或插图）。" : text))
            }
            guard total > 0 else { throw SourceError.message("PDF 没有可提取的文字，OCR 也未识别到正文。请检查是否为空白、纯插图或扫描质量过低。") }
            return BookDocument(chapters: chapters, pages: pages, wordCount: pages.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count })
            #else
            throw SourceError.message("当前平台不支持 PDF 解析。")
            #endif
        case "rtf":
            #if canImport(UIKit) || canImport(AppKit)
            guard data.count <= TextParser.maximumBytes else { throw TextImportError.tooLarge }
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            return try TextParser.parse(text)
            #else
            throw SourceError.message("当前平台不支持 RTF。")
            #endif
        default: throw SourceError.message("暂不支持 .\(ext) 格式。可导入 TXT、EPUB、PDF、Markdown、HTML、RTF、DOCX 和未加密的 MOBI/AZW3。")
        }
    }

    static func htmlText(_ data: Data) throws -> String {
        let doc = try SwiftSoup.parse(TextParser.decode(data))
        try doc.select("script, style, noscript, iframe").remove()
        try doc.select("br").before(" MOYU_PARAGRAPH ")
        try doc.select("p, div, h1, h2, h3, li").before(" MOYU_PARAGRAPH ")
        return try doc.body()?.text().components(separatedBy: "MOYU_PARAGRAPH")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n") ?? ""
    }

    private static func read(_ path: String, archive: Archive, limit: Int = 20 * 1024 * 1024) throws -> Data {
        guard !path.hasPrefix("/"), !path.components(separatedBy: "/").contains(".."),
              let entry = archive[path], entry.type == .file else { throw SourceError.message("电子书缺少文件：\(path)") }
        guard entry.uncompressedSize <= UInt64(limit) else { throw SourceError.message("电子书中的单个文件过大。") }
        var result = Data()
        _ = try archive.extract(entry) { chunk in
            guard result.count + chunk.count <= limit else { throw SourceError.message("解压内容超过限制。") }
            result.append(chunk)
        }
        return result
    }

    private static func epub(_ data: Data) throws -> BookDocument {
        let publication = try EPUBPublication.load(data)
        var pages: [ReadingPage] = [], chapters: [Chapter] = []
        var count = 0, expandedBytes = 0
        for item in publication.chapters {
            try Task.checkCancellation()
            guard let content = publication.resources[item.path] else { throw SourceError.message("EPUB 缺少章节正文。") }
            expandedBytes += content.count
            guard expandedBytes <= 40 * 1024 * 1024 else { throw SourceError.message("EPUB 解压文字超过 40 MB。") }
            let text = try htmlText(content)
            let parsed = try TextParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "本节包含图片或原书版式，请使用 EPUB 原版阅读查看。" : text)
            let chapter = chapters.count
            chapters.append(Chapter(id: chapter, title: item.title, firstPage: pages.count))
            let firstPage = pages.count
            pages += parsed.pages.map { ReadingPage(id: firstPage + $0.id, chapter: chapter, text: $0.text) }
            count += parsed.wordCount
        }
        return BookDocument(chapters: chapters, pages: pages, wordCount: count)
    }
}

final class XMLBookNode: NSObject, XMLParserDelegate {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLBookNode] = []
    private var stack: [XMLBookNode] = []
    init(name: String = "root", attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [XMLBookNode] {
        children.flatMap { node in (node.name.components(separatedBy: ":").last == name ? [node] : []) + node.descendants(name) }
    }
    static func parse(_ data: Data) throws -> XMLBookNode {
        let root = XMLBookNode()
        root.stack = [root]
        defer { root.stack = [] }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = root
        guard parser.parse() else { throw SourceError.message("电子书 XML 损坏：\(parser.parserError?.localizedDescription ?? "格式错误")") }
        root.stack = []
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 256 else { parser.abortParsing(); return }
        let node = XMLBookNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
}
