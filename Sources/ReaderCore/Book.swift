import Foundation

public struct ReadingPage: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var chapter: Int
    public var text: String
}

public struct Chapter: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var firstPage: Int
}

public struct BookDocument: Codable, Equatable, Sendable {
    public var chapters: [Chapter]
    public var pages: [ReadingPage]
    public var wordCount: Int

    public func search(_ query: String) -> [ReadingPage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return Array(pages.lazy.filter { $0.text.localizedCaseInsensitiveContains(term) }.prefix(100))
    }
}

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { page }
    public var page: Int
    public var excerpt: String
    public var createdAt: Date

    public init(page: Int, excerpt: String, createdAt: Date = Date()) {
        self.page = page
        self.excerpt = excerpt
        self.createdAt = createdAt
    }
}

public struct Book: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var addedAt: Date
    public var lastReadAt: Date?
    public var textOffset: Int?
    public var scrollFraction: Double?
    public var page: Int
    public var pageCount: Int
    public var chapterCount: Int
    public var wordCount: Int
    public var bookmarks: [Bookmark]
    public var colorIndex: Int

    public init(title: String, document: BookDocument, colorIndex: Int = 0) {
        id = UUID()
        self.title = title
        addedAt = Date()
        page = 0
        pageCount = document.pages.count
        chapterCount = document.chapters.count
        wordCount = document.wordCount
        bookmarks = []
        self.colorIndex = colorIndex
    }

    public var progress: Double {
        guard pageCount > 0, lastReadAt != nil else { return 0 }
        return min(1, max(0, Double(page + 1) / Double(pageCount)))
    }
}

public enum TextImportError: LocalizedError {
    case tooLarge, unsupportedEncoding, empty

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件超过 20 MB，请拆分后再导入。"
        case .unsupportedEncoding: return "无法识别文本编码，请将文件另存为 UTF-8 后重试。"
        case .empty: return "文件没有可阅读的内容。"
        }
    }
}

public enum TextParser {
    public static let maximumBytes = 20 * 1024 * 1024

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw TextImportError.tooLarge }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16BigEndian)
        } else {
            // Apple's NSString encoding value for GB 18030 (also covers common GBK files).
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: String.Encoding(rawValue: 0x80000632))
        }
        guard let text, !text.contains("\0") else { throw TextImportError.unsupportedEncoding }
        return text.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    public static func parse(_ text: String, pageSize: Int = 800) throws -> BookDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextImportError.empty
        }
        let heading = try NSRegularExpression(
            pattern: #"^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节卷回部篇集].{0,60}|(?:Chapter|CHAPTER|chapter)\s+[0-9IVXivx]+.{0,60}|序章.{0,40}|楔子.{0,40}|尾声.{0,40}|后记.{0,40})$"#
        )
        var chapters: [Chapter] = []
        var pages: [ReadingPage] = []
        var buffer = ""
        var chapterIndex = 0
        let limit = max(80, pageSize)

        func flush() {
            let content = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                pages.append(ReadingPage(id: pages.count, chapter: chapterIndex, text: content))
            }
            buffer = ""
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            let isHeading = line.count <= 80 && heading.firstMatch(in: line, range: range) != nil
            if isHeading {
                flush()
                chapterIndex = chapters.count
                chapters.append(Chapter(id: chapterIndex, title: line, firstPage: pages.count))
            } else if chapters.isEmpty && !line.isEmpty {
                chapters.append(Chapter(id: 0, title: "正文", firstPage: 0))
            }
            guard !line.isEmpty else { continue }
            // Chunk by Character so surrogate pairs, emoji and composed characters survive.
            var rest = line[...]
            while !rest.isEmpty {
                let room = limit - buffer.count
                if room <= 1 { flush(); continue }
                let end = rest.index(rest.startIndex, offsetBy: room, limitedBy: rest.endIndex) ?? rest.endIndex
                buffer += rest[..<end]
                rest = rest[end...]
                if !rest.isEmpty { flush() }
            }
            buffer += "\n\n"
            if buffer.count >= limit { flush() }
        }
        flush()
        return BookDocument(chapters: chapters, pages: pages,
                            wordCount: normalized.filter { !$0.isWhitespace }.count)
    }
}
