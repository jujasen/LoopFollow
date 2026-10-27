// LoopFollow
// TIRDataPoint.swift

import Foundation

struct TIRDataPoint {
    let period: TIRPeriod
    let veryLow: Double
    let low: Double
    let inRange: Double
    let high: Double
    let veryHigh: Double
}

enum TIRPeriod: String, CaseIterable {
    case night = "Night"
    case morning = "Morning"
    case day = "Day"
    case evening = "Evening"
    case average = "Average"

    var displayName: String {
        switch self {
        case .night: return String(localized: "Night", comment: "Time in range period: 00-06")
        case .morning: return String(localized: "Morning", comment: "Time in range period: 06-12")
        case .day: return String(localized: "Day", comment: "Time in range period: 12-18")
        case .evening: return String(localized: "Evening", comment: "Time in range period: 18-24")
        case .average: return String(localized: "Average", comment: "Time in range period: whole day")
        }
    }

    var hourRange: (start: Int, end: Int)? {
        switch self {
        case .night:
            return (0, 6)
        case .morning:
            return (6, 12)
        case .day:
            return (12, 18)
        case .evening:
            return (18, 24)
        case .average:
            return nil
        }
    }
}
