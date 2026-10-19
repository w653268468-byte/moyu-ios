import Foundation

public enum ReadingTapAction: String, CaseIterable, Codable, Sendable {
    case previous, menu, next, none
    public var name: String {
        switch self { case .previous: return "上一页"; case .menu: return "菜单"; case .next: return "下一页"; case .none: return "无操作" }
    }
}

/// Nine zones in row-major order. Coordinates cover the whole reading viewport, including margins.
public struct ReadingTapMap: Equatable, Sendable {
    public var actions: [ReadingTapAction]
    public static let allNext = ReadingTapMap(actions: Array(repeating: .next, count: 9))
    public static let classic = ReadingTapMap(actions: Array(repeating: [.previous, .menu, .next], count: 3).flatMap { $0 })
    public init(actions: [ReadingTapAction]) { self.actions = actions.count == 9 ? actions : Self.classic.actions }
    public init(stored: String) {
        let parts = stored.split(separator: ",", omittingEmptySubsequences: false).compactMap { ReadingTapAction(rawValue: String($0)) }
        self.init(actions: parts)
    }
    public var stored: String { actions.map(\.rawValue).joined(separator: ",") }
    public func action(x: Double, y: Double, width: Double, height: Double) -> ReadingTapAction {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return .none }
        let column = min(2, max(0, Int(min(1, max(0, x / width)) * 3)))
        let row = min(2, max(0, Int(min(1, max(0, y / height)) * 3)))
        return actions[row * 3 + column]
    }
}
