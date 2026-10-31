import Foundation

public struct ReadingActivity: Codable, Identifiable, Equatable, Sendable {
    public var id: String { day + "|" + bookKey }
    public var day: String
    public var bookKey: String
    public var title: String
    public var chapter: String
    public var seconds: Double
    public var lastRead: Date
}

public struct ReadingActivityLedger: Codable, Sendable {
    public private(set) var entries: [ReadingActivity] = []
    public init() {}
    public mutating func record(bookKey: String, title: String, chapter: String, seconds: Double, at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        guard !bookKey.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if let index = entries.firstIndex(where: { $0.day == day && $0.bookKey == bookKey }) {
            entries[index].title = title; entries[index].chapter = chapter
            entries[index].seconds += min(60, seconds); entries[index].lastRead = date
        } else {
            entries.append(ReadingActivity(day: day, bookKey: bookKey, title: title, chapter: chapter, seconds: min(60, seconds), lastRead: date))
        }
        entries.sort { $0.lastRead > $1.lastRead }
        if entries.count > 3000 { entries.removeLast(entries.count - 3000) }
    }
}

public enum ReadingPrefetchPolicy {
    public static func count(mode: String, charactersPerMinute: Double, chapterCharacters: Int) -> Int {
        if mode == "off" { return 0 }
        if mode == "two" { return 2 }
        let speed = charactersPerMinute.isFinite ? min(3000, max(300, charactersPerMinute)) : 600
        return min(6, max(2, Int(ceil(speed * 5 / Double(max(500, chapterCharacters))))))
    }
}

public enum ChapterReadingPosition {
    /// Only reuse an offset when a surrounding text anchor is found uniquely.
    /// Different editions without that anchor start at the matched chapter.
    public static func alignedOffset(original: String, offset: Int, replacement: String) -> Int {
        guard offset > 0, offset < original.count else { return 0 }
        let start = original.index(original.startIndex, offsetBy: max(0, offset - 20))
        let end = original.index(start, offsetBy: min(60, original.distance(from: start, to: original.endIndex)))
        let anchor = String(original[start..<end])
        guard anchor.count >= 20, let match = replacement.range(of: anchor),
              replacement.range(of: anchor, range: match.upperBound..<replacement.endIndex) == nil else { return 0 }
        return replacement.distance(from: replacement.startIndex, to: match.lowerBound) + offset - original.distance(from: original.startIndex, to: start)
    }
}

/// Tracks only automatically prefetched files. Explicit offline downloads and
/// the foreground chapter are protected by the caller on every prune.
public actor AutomaticChapterCache {
    private let directory: URL
    private var entries: [String: Date]?
    public init(directory: URL) { self.directory = directory }
    public func register(_ file: URL, budgetBytes: Int, protected: Set<String>) throws {
        let manifest = directory.appendingPathComponent("prefetch-cache.json")
        if entries == nil { entries = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: manifest))) ?? [:] }
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              file.lastPathComponent.range(of: "^[a-f0-9]{64}\\.txt$", options: .regularExpression) != nil else { return }
        entries?[file.lastPathComponent] = Date()
        var total = 0
        for name in Array(entries?.keys ?? Dictionary<String, Date>().keys) {
            guard name.range(of: "^[a-f0-9]{64}\\.txt$", options: .regularExpression) != nil else { entries?.removeValue(forKey: name); continue }
            let url = directory.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += size }
            else { entries?.removeValue(forKey: name) }
        }
        for (name, _) in (entries ?? [:]).sorted(by: { $0.value < $1.value }) where total > max(0, budgetBytes) && !protected.contains(name) {
            let url = directory.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try FileManager.default.removeItem(at: url); total -= size; entries?.removeValue(forKey: name)
        }
        try JSONEncoder().encode(entries ?? [:]).write(to: manifest, options: .atomic)
    }
}
