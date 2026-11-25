// LoopFollow
// StatsDisplayModel.swift

import Foundation

class StatsDisplayModel: ObservableObject {
    @Published var lowPercent: String = ""
    @Published var inRangePercent: String = ""
    @Published var highPercent: String = ""
    @Published var avgBG: String = ""
    @Published var estA1C: String = ""
    @Published var estA1CTitle: String = .init(localized: "Est A1C:")
    @Published var stdDev: String = ""
    @Published var stdDevTitle: String = .init(localized: "Std Dev:")
    @Published var pieLow: Double = 0
    @Published var pieRange: Double = 0
    @Published var pieHigh: Double = 0

    // Time in Range band (same period as the statistics box)
    @Published var bandTitle: String = "Time in Range"
    @Published var bandPeriod: String = "last 24h"
    @Published var bandHasData: Bool = false
    @Published var bandVeryLowPct: Double = 0
    @Published var bandLowPct: Double = 0
    @Published var bandInRangePct: Double = 0
    @Published var bandHighPct: Double = 0
    @Published var bandVeryHighPct: Double = 0
    /// How long the band's period is so far (24 h, or the time since midnight).
    @Published var bandPeriodSeconds: Double = 24 * 3600
    @Published var bandSinceMidnight: Bool = false

    /// The plain-language summary Home shows.
    var timeInRangeSummary: TimeInRangeSummary {
        TimeInRangeSummary(
            veryLow: bandVeryLowPct, low: bandLowPct, inRange: bandInRangePct,
            high: bandHighPct, veryHigh: bandVeryHighPct,
            periodSeconds: bandPeriodSeconds, sinceMidnight: bandSinceMidnight, hasData: bandHasData
        )
    }
}
