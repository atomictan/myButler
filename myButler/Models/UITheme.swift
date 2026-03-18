import SwiftUI

enum UITheme: String, CaseIterable, Identifiable {
    case classicBlue
    case pinkDino
    case lavender
    case mint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classicBlue:
            return "Blue"
        case .pinkDino:
            return "Pink"
        case .lavender:
            return "Lavender"
        case .mint:
            return "Mint"
        }
    }

    var tintColor: Color {
        switch self {
        case .classicBlue:
            return .blue
        case .pinkDino:
            return Color(red: 0.95, green: 0.38, blue: 0.67)
        case .lavender:
            return Color(red: 0.57, green: 0.46, blue: 0.91)
        case .mint:
            return Color(red: 0.20, green: 0.72, blue: 0.62)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .classicBlue:
            return Color(red: 0.73, green: 0.85, blue: 1.0)
        case .pinkDino:
            return Color(red: 1.0, green: 0.84, blue: 0.91)
        case .lavender:
            return Color(red: 0.86, green: 0.82, blue: 0.98)
        case .mint:
            return Color(red: 0.80, green: 0.96, blue: 0.91)
        }
    }
}
