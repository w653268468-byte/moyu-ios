import Foundation

public enum ChapterOrder {
    /// Display order only. Values always refer to the original catalog positions.
    public static func indices(count: Int, descending: Bool) -> [Int] {
        let values = Array(0..<max(0, count))
        return descending ? Array(values.reversed()) : values
    }
}

public struct OfflineDownloadState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case downloading, paused, completed, failed }
    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var failed: [String]
    public var message: String
    public init(phase: Phase = .paused, completed: Int = 0, total: Int = 0, failed: [String] = [], message: String = "") {
        self.phase = phase; self.completed = completed; self.total = total; self.failed = failed; self.message = message
    }
    public var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
}
