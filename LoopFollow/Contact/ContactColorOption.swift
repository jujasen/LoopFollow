// LoopFollow
// ContactColorOption.swift

import UIKit

enum ContactColorOption: String, CaseIterable {
    case red, blue, cyan, green, yellow, orange, purple, white, black

    var displayName: String {
        switch self {
        case .red: return String(localized: "Red")
        case .blue: return String(localized: "Blue")
        case .cyan: return String(localized: "Cyan")
        case .green: return String(localized: "Green")
        case .yellow: return String(localized: "Yellow")
        case .orange: return String(localized: "Orange")
        case .purple: return String(localized: "Purple")
        case .white: return String(localized: "White")
        case .black: return String(localized: "Black")
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: return .red
        case .blue: return .blue
        case .cyan: return .cyan
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .purple: return .purple
        case .white: return .white
        case .black: return .black
        }
    }
}
