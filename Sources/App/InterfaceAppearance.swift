import SwiftUI
import UIKit

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case light, system, dark
    var id: String { rawValue }
    var name: String { switch self { case .light: return "浅色纸白"; case .system: return "跟随系统"; case .dark: return "深色" } }
    var scheme: ColorScheme? { switch self { case .light: return .light; case .dark: return .dark; case .system: return nil } }
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : UIColor(red: 0.975, green: 0.965, blue: 0.94, alpha: 1)
    })
}
