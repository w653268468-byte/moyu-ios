import Foundation

public struct OnlineReadingMark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var chapterID: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var textOffset: Int
    public var excerpt: String
    public var note: String
    public var createdAt: Date
    public init(chapter: OnlineChapter, index: Int, offset: Int, text: String, note: String = "") {
        id = UUID(); chapterID = chapter.id; chapterIndex = index; chapterTitle = chapter.title
        let ns = TextPagination.readingText(text) as NSString
        textOffset = min(max(0, offset), ns.length)
        if textOffset < ns.length { textOffset = ns.rangeOfComposedCharacterSequence(at: textOffset).location }
        excerpt = String(ns.substring(from: textOffset).prefix(100)); self.note = String(note.prefix(4000)); createdAt = Date()
    }
    public func destination(in chapters: [OnlineChapter]) -> Int? {
        if let exact = chapters.firstIndex(where: { $0.id == chapterID }) { return exact }
        let key = BookSearchPresentation.normalized(chapterTitle)
        if chapters.indices.contains(chapterIndex), BookSearchPresentation.normalized(chapters[chapterIndex].title) == key { return chapterIndex }
        let matches = chapters.indices.filter { BookSearchPresentation.normalized(chapters[$0].title) == key }
        return matches.count == 1 ? matches[0] : nil
    }
}
