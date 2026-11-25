// LoopFollow
// HomeFormatting.swift

import Foundation
import SwiftUI

// MARK: - Loop freshness

/// How fresh Loop's last run is, with the same limits Loop uses for the ring at the
/// top of its own status screen: green up to 6 minutes, yellow up to 16, red after.
enum LoopFreshness: Equatable {
    case fresh
    case aging
    case stale
    /// No loop run seen yet.
    case unknown

    static let freshLimit: TimeInterval = 6 * 60
    static let agingLimit: TimeInterval = 16 * 60

    init(lastLoop: Date?, now: Date) {
        guard let lastLoop else {
            self = .unknown
            return
        }
        let age = max(0, now.timeIntervalSince(lastLoop))
        if age <= Self.freshLimit {
            self = .fresh
        } else if age <= Self.agingLimit {
            self = .aging
        } else {
            self = .stale
        }
    }

    /// The last loop time LoopFollow keeps (Unix seconds, 0 or nil when none).
    init(lastLoopTime: TimeInterval?, now: Date) {
        if let lastLoopTime, lastLoopTime > 0 {
            self.init(lastLoop: Date(timeIntervalSince1970: lastLoopTime), now: now)
        } else {
            self.init(lastLoop: nil, now: now)
        }
    }

    var color: Color {
        switch self {
        case .fresh: return .green
        case .aging: return .yellow
        case .stale: return .red
        case .unknown: return .secondary
        }
    }

    /// "2 min", "1 h 5 min" — how long ago Loop last ran, under the ring.
    static func ageText(lastLoop: Date?, now: Date) -> String {
        guard let lastLoop else { return "–" }
        let minutes = max(0, Int(now.timeIntervalSince(lastLoop) / 60))
        if minutes < 60 {
            return String(format: String(localized: "%lld min", table: "Home", comment: "Minutes since Loop last ran, under the loop ring"), minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: String(localized: "%lld h", table: "Home", comment: "Hours since Loop last ran, under the loop ring"), hours)
        }
        return String(format: String(localized: "%lld d", table: "Home", comment: "Days since Loop last ran, under the loop ring"), hours / 24)
    }
}

// MARK: - Durations

enum HomeDurationFormat {
    /// "18 h 43 min", "4 h", "30 min" — a time span in plain words, without the
    /// commas the system formatter puts between units in some languages.
    static func hoursMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return String(format: String(localized: "%lld min", table: "Home"), minutes)
        }
        if minutes == 0 {
            return String(format: String(localized: "%lld h", table: "Home"), hours)
        }
        return String(format: String(localized: "%lld h %lld min", table: "Home", comment: "A duration: hours and minutes"), hours, minutes)
    }

    /// "5 d 23 h", "7 h", "1 h 20 min", "45 min" — a pod's age or a sensor's time
    /// left, short enough for the HUD. Rounds down, so time left is never overstated.
    static func compact(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            if hours == 0 {
                return String(format: String(localized: "%lld d", table: "Home"), days)
            }
            return String(format: String(localized: "%lld d %lld h", table: "Home", comment: "A duration: days and hours"), days, hours)
        }
        if totalMinutes >= 120 || (hours > 0 && minutes == 0) {
            return String(format: String(localized: "%lld h", table: "Home"), hours)
        }
        if hours > 0 {
            return String(format: String(localized: "%lld h %lld min", table: "Home"), hours, minutes)
        }
        return String(format: String(localized: "%lld min", table: "Home"), minutes)
    }
}

// MARK: - Time in range

/// The plain-language statistics card: one headline number and three bands.
struct TimeInRangeSummary: Equatable {
    struct Band: Equatable {
        /// Share of the readings, 0–100.
        let percent: Double
        /// The same share of the period, as time.
        let duration: TimeInterval
    }

    let low: Band
    let inRange: Band
    let high: Band
    let sinceMidnight: Bool
    let hasData: Bool

    /// - Parameters:
    ///   - veryLow…veryHigh: percentages from the Time in Range band (0–100).
    ///   - periodSeconds: how long the period covered by the percentages is.
    init(veryLow: Double, low: Double, inRange: Double, high: Double, veryHigh: Double,
         periodSeconds: TimeInterval, sinceMidnight: Bool, hasData: Bool)
    {
        func band(_ percent: Double) -> Band {
            Band(percent: percent, duration: periodSeconds * percent / 100)
        }
        self.low = band(veryLow + low)
        self.inRange = band(inRange)
        self.high = band(high + veryHigh)
        self.sinceMidnight = sinceMidnight
        self.hasData = hasData
    }

    /// "78 %", "<1 %" for a small share that would otherwise read as none, "0 %".
    static func percentText(_ percent: Double, locale: Locale = .current) -> String {
        if percent > 0, percent < 0.5 {
            return "<" + (0.01).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }
        return (percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "Today: 78 % in range" / "Last 24 h: 78 % in range".
    func headline(locale: Locale = .current) -> String {
        let percent = hasData ? Self.percentText(inRange.percent, locale: locale) : "–"
        if sinceMidnight {
            return String(format: String(localized: "Today: %@ in range", table: "Home", comment: "Statistics card headline; 1: percentage"), percent)
        }
        return String(format: String(localized: "Last 24 h: %@ in range", table: "Home", comment: "Statistics card headline; 1: percentage"), percent)
    }

    /// The second line under a band's name: its time, or nothing while there is no data.
    static func durationText(_ band: Band, hasData: Bool) -> String {
        guard hasData else { return "" }
        return HomeDurationFormat.hoursMinutes(band.duration)
    }
}

// MARK: - The four numbers

enum HomeNumbers {
    /// The rate running now from the info table's basal value, which reads
    /// "0,6 → 0,45" when a temp basal differs from the scheduled one.
    static func currentBasal(fromInfoValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: InfoDataSeparator.arrow.rawValue)
        let current = parts.last?.trimmingCharacters(in: .whitespaces) ?? trimmed
        return current.isEmpty ? nil : current
    }

    /// "1,8 U" — a value from the info table with its unit, or nil when empty.
    static func withUnit(_ value: String, _ unit: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "—" else { return nil }
        return trimmed + " " + unit
    }
}

/// Loop's glucose forecast: values in mg/dL every five minutes from `start`.
struct LoopPredictionCurve: Equatable {
    let start: Date
    let valuesMgdl: [Double]

    static let step: TimeInterval = 5 * 60

    /// The forecast at `date`, interpolated between the five-minute points;
    /// nil before the start or past the end of the forecast.
    func value(at date: Date) -> Double? {
        guard !valuesMgdl.isEmpty else { return nil }
        let offset = date.timeIntervalSince(start) / Self.step
        guard offset >= 0, offset <= Double(valuesMgdl.count - 1) else { return nil }
        let lower = Int(offset.rounded(.down))
        let upper = min(lower + 1, valuesMgdl.count - 1)
        let fraction = offset - Double(lower)
        return valuesMgdl[lower] + (valuesMgdl[upper] - valuesMgdl[lower]) * fraction
    }
}

// MARK: - Chart span

enum ChartSpan: TimeInterval, CaseIterable, Identifiable {
    case three = 10800
    case six = 21600
    case twelve = 43200
    case twentyFour = 86400

    var id: TimeInterval { rawValue }

    var hours: Int { Int(rawValue / 3600) }

    var label: String {
        String(format: String(localized: "%lld h", table: "Home"), hours)
    }

    /// The span the chart shows now, when it is one of these (a pinch can leave it in between).
    static func matching(visibleSeconds: TimeInterval) -> ChartSpan? {
        allCases.first { abs($0.rawValue - visibleSeconds) <= $0.rawValue * 0.03 }
    }

    /// Where the chart's leading edge goes for `seconds` of view with "now" at
    /// `nowFraction` of the width, kept inside the loaded data.
    static func leadingEdge(seconds: TimeInterval, now: Date, nowFraction: Double,
                            domainStart: Date, domainEnd: Date) -> Date
    {
        let proposed = now.addingTimeInterval(-seconds * nowFraction)
        // Before the first data load the domain is a placeholder; don't clamp to it.
        guard domainEnd > domainStart.addingTimeInterval(1) else { return proposed }
        let latest = domainEnd.addingTimeInterval(-seconds)
        return min(max(proposed, domainStart), max(domainStart, latest))
    }
}
