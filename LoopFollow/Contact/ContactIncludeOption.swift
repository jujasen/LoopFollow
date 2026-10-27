// LoopFollow
// ContactIncludeOption.swift

enum ContactIncludeOption: String, Codable, Equatable, CaseIterable {
    case off = "Off"
    case include = "Include"
    case separate = "Separate"

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .include: return String(localized: "Include")
        case .separate: return String(localized: "Separate")
        }
    }
}
