// LoopFollow
// ContactType.swift

enum ContactType: String, CaseIterable, Codable {
    case BG
    case Trend
    case Delta
    case IOB

    var displayName: String {
        switch self {
        case .BG: return String(localized: "BG")
        case .Trend: return String(localized: "Trend")
        case .Delta: return String(localized: "Delta")
        case .IOB: return String(localized: "IOB")
        }
    }
}
