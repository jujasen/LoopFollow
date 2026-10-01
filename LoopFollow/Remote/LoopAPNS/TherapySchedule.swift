// LoopFollow
// TherapySchedule.swift

import Foundation
import HealthKit

/// The single-value Loop schedules that can be changed remotely. The correction range, a schedule
/// of low–high ranges, is a `TherapyRangeEntry` schedule.
enum TherapySettingKind: String, CaseIterable, Identifiable {
    case carbRatio
    case basalRate
    case insulinSensitivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carbRatio: return "Carb Ratios"
        case .basalRate: return "Basal Rates"
        case .insulinSensitivity: return "Insulin Sensitivities"
        }
    }

    /// The unit a value is edited in. Insulin sensitivity follows the Nightscout profile's glucose unit.
    func unitLabel(glucoseUnit: HKUnit) -> String {
        switch self {
        case .carbRatio: return "g/U"
        case .basalRate: return "U/h"
        case .insulinSensitivity: return "\(glucoseUnit.localizedShortUnitString)/U"
        }
    }

    func fractionDigits(glucoseUnit: HKUnit) -> Int {
        switch self {
        case .carbRatio: return 1
        case .basalRate: return 2
        case .insulinSensitivity: return glucoseUnit == .millimolesPerLiter ? 1 : 0
        }
    }

    /// The pump's increment, when values must land on one (Omnipod DASH: 0.05 U/h).
    var increment: Double? {
        self == .basalRate ? TherapyGuardrails.pumpIncrement : nil
    }

    /// Omnipod DASH holds at most 24 basal rates; Loop's other schedules allow one per half hour.
    var maximumEntryCount: Int {
        self == .basalRate ? TherapyGuardrails.maximumBasalScheduleEntryCount : TherapySchedule.maximumEntryCount
    }

    /// Loop's absolute guardrails (`Guardrail.carbRatio` / `Guardrail.insulinSensitivity` /
    /// `Guardrail.basalRate` for an Omnipod DASH in LoopKit). Loop checks them again and rejects the
    /// whole command if a value falls outside.
    func allowedRange(glucoseUnit: HKUnit) -> ClosedRange<Double> {
        switch self {
        case .carbRatio:
            return 2 ... 150
        case .basalRate:
            return TherapyGuardrails.supportedBasalRates
        case .insulinSensitivity:
            let lower = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 9.1).doubleValue(for: glucoseUnit)
            let upper = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 500.9).doubleValue(for: glucoseUnit)
            return lower ... upper
        }
    }

    /// Loop's recommended bounds; a value outside gets a warning, as in Loop's editors, but can be sent.
    func recommendedRange(glucoseUnit: HKUnit) -> ClosedRange<Double> {
        switch self {
        case .carbRatio:
            return 4 ... 28
        case .basalRate:
            return TherapyGuardrails.supportedBasalRates
        case .insulinSensitivity:
            let lower = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 15.1).doubleValue(for: glucoseUnit)
            let upper = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 399.9).doubleValue(for: glucoseUnit)
            return lower ... upper
        }
    }
}

/// A row of any schedule: something that applies from `start` (seconds after midnight) until the next row.
protocol TherapyScheduleRow: Identifiable, Equatable where ID == UUID {
    var id: UUID { get }
    var start: Int { get }
}

/// One row of a schedule: a value that applies from `start` (seconds after midnight) until the next row.
struct TherapyScheduleEntry: TherapyScheduleRow {
    let id: UUID
    var start: Int
    var value: Double

    init(id: UUID = UUID(), start: Int, value: Double) {
        self.id = id
        self.start = start
        self.value = value
    }

    static func == (lhs: TherapyScheduleEntry, rhs: TherapyScheduleEntry) -> Bool {
        lhs.start == rhs.start && lhs.value == rhs.value
    }
}

/// One row of the correction range schedule: a low–high range from `start` until the next row.
struct TherapyRangeEntry: TherapyScheduleRow {
    let id: UUID
    var start: Int
    var low: Double
    var high: Double

    init(id: UUID = UUID(), start: Int, low: Double, high: Double) {
        self.id = id
        self.start = start
        self.low = low
        self.high = high
    }

    static func == (lhs: TherapyRangeEntry, rhs: TherapyRangeEntry) -> Bool {
        lhs.start == rhs.start && lhs.low == rhs.low && lhs.high == rhs.high
    }
}

enum TherapySchedule {
    /// Loop's editors step in half hours, and allow at most one row per step.
    static let step = 30 * 60
    static let maximumEntryCount = 48
    static let day = 24 * 60 * 60

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case mustStartAtMidnight
        case duplicateTime(Int)
        case tooManyTimes(Int)
        case outOfRange(TherapySettingKind, Double, ClosedRange<Double>)
        case unsupportedIncrement(Double, Double)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "The schedule needs at least one time."
            case .mustStartAtMidnight:
                return "The first time must be 00:00."
            case let .duplicateTime(start):
                return "\(TherapySchedule.timeString(start)) is used more than once."
            case let .tooManyTimes(maximum):
                return "The pump holds at most \(maximum) times."
            case let .outOfRange(_, value, range):
                return String(format: "%@ is outside what Loop allows (%@–%@).",
                              format(value), format(range.lowerBound), format(range.upperBound))
            case let .unsupportedIncrement(value, increment):
                return String(format: "%@ is not a step of %@ the pump can deliver.", format(value, digits: 3), format(increment, digits: 2))
            }
        }

        private func format(_ value: Double, digits: Int = 1) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = max(digits, value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)
            return formatter.string(from: value as NSNumber) ?? "\(value)"
        }
    }

    static func entries(from schedule: [ProfileManager.TimeValue<Double>]) -> [TherapyScheduleEntry] {
        sorted(schedule.map { TherapyScheduleEntry(start: $0.timeAsSeconds, value: $0.value) })
    }

    static func entries(from schedule: [ProfileManager.TimeValue<HKQuantity>], unit: HKUnit) -> [TherapyScheduleEntry] {
        sorted(schedule.map { TherapyScheduleEntry(start: $0.timeAsSeconds, value: $0.value.doubleValue(for: unit)) })
    }

    /// The correction range from the profile's separate low and high schedules, which Loop uploads
    /// with the same start times. A start present in only one of them takes the other's value in effect.
    static func rangeEntries(low: [ProfileManager.TimeValue<HKQuantity>], high: [ProfileManager.TimeValue<HKQuantity>], unit: HKUnit) -> [TherapyRangeEntry] {
        let lows = entries(from: low, unit: unit)
        let highs = entries(from: high, unit: unit)
        guard !lows.isEmpty, !highs.isEmpty else { return [] }
        let starts = Set(lows.map(\.start)).union(highs.map(\.start)).sorted()
        return starts.compactMap { start in
            guard let low = value(at: start, in: lows), let high = value(at: start, in: highs) else { return nil }
            return TherapyRangeEntry(start: start, low: low, high: high)
        }
    }

    static func sorted<Row: TherapyScheduleRow>(_ entries: [Row]) -> [Row] {
        entries.sorted { $0.start < $1.start }
    }

    /// The shape Loop requires of every schedule: at least one row, the first at midnight, no time twice.
    static func validateShape<Row: TherapyScheduleRow>(_ entries: [Row], maximumCount: Int = maximumEntryCount) throws {
        let entries = sorted(entries)
        guard let first = entries.first else { throw ValidationError.empty }
        guard first.start == 0 else { throw ValidationError.mustStartAtMidnight }
        guard entries.count <= maximumCount else { throw ValidationError.tooManyTimes(maximumCount) }

        var seen = Set<Int>()
        for entry in entries {
            guard seen.insert(entry.start).inserted else { throw ValidationError.duplicateTime(entry.start) }
        }
    }

    static func validate(_ entries: [TherapyScheduleEntry], kind: TherapySettingKind, glucoseUnit: HKUnit) throws {
        try validateShape(entries, maximumCount: kind.maximumEntryCount)

        let range = allowedRangeRounded(kind: kind, glucoseUnit: glucoseUnit)
        for entry in sorted(entries) {
            guard range.contains(entry.value) else {
                throw ValidationError.outOfRange(kind, entry.value, range)
            }
            if let increment = kind.increment, !TherapyGuardrails.isMultiple(entry.value, of: increment) {
                throw ValidationError.unsupportedIncrement(entry.value, increment)
            }
        }
    }

    /// The guardrail range, narrowed to values that can be typed at the editor's precision, so a
    /// value shown as allowed here is never rejected by Loop for a rounding difference.
    static func allowedRangeRounded(kind: TherapySettingKind, glucoseUnit: HKUnit) -> ClosedRange<Double> {
        roundedInward(kind.allowedRange(glucoseUnit: glucoseUnit), digits: kind.fractionDigits(glucoseUnit: glucoseUnit))
    }

    static func roundedInward(_ range: ClosedRange<Double>, digits: Int) -> ClosedRange<Double> {
        let scale = pow(10, Double(digits))
        // A tiny tolerance keeps an exact bound (2.0, 0.05) from being pushed inward by float noise.
        let lower = (range.lowerBound * scale - 1e-9).rounded(.up) / scale
        let upper = (range.upperBound * scale + 1e-9).rounded(.down) / scale
        return lower ... max(lower, upper)
    }

    /// Half-hour start times not yet taken by another row.
    static func availableStarts<Row: TherapyScheduleRow>(in entries: [Row], keeping current: Int? = nil) -> [Int] {
        let taken = Set(entries.map(\.start)).subtracting(current.map { [$0] } ?? [])
        return stride(from: 0, to: day, by: step).filter { !taken.contains($0) }
    }

    /// The first free half hour after the last row (or the first free one at all).
    static func newStart<Row: TherapyScheduleRow>(after entries: [Row], maximumCount: Int = maximumEntryCount) -> Int? {
        let entries = sorted(entries)
        guard entries.count < maximumCount else { return nil }
        let free = availableStarts(in: entries)
        let lastStart = entries.last?.start ?? -1
        return free.first(where: { $0 > lastStart }) ?? free.first
    }

    /// A new row: the first free half hour after the last row (or the first free one at all), starting
    /// out with the value already in effect at that time, so adding a row changes nothing until edited.
    static func newEntry(after entries: [TherapyScheduleEntry], maximumCount: Int = maximumEntryCount) -> TherapyScheduleEntry? {
        guard let start = newStart(after: entries, maximumCount: maximumCount) else { return nil }
        return TherapyScheduleEntry(start: start, value: value(at: start, in: entries) ?? 0)
    }

    static func newRangeEntry(after entries: [TherapyRangeEntry]) -> TherapyRangeEntry? {
        guard let start = newStart(after: entries),
              let current = sorted(entries).last(where: { $0.start <= start }) ?? entries.first
        else { return nil }
        return TherapyRangeEntry(start: start, low: current.low, high: current.high)
    }

    static func value(at start: Int, in entries: [TherapyScheduleEntry]) -> Double? {
        sorted(entries).last(where: { $0.start <= start })?.value
    }

    static func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    static func round(_ value: Double, digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }

    /// Rounds to what the editor can show, so an unchanged schedule compares equal to the profile.
    static func rounded(_ entries: [TherapyScheduleEntry], kind: TherapySettingKind, glucoseUnit: HKUnit) -> [TherapyScheduleEntry] {
        let digits = kind.fractionDigits(glucoseUnit: glucoseUnit)
        return entries.map { TherapyScheduleEntry(id: $0.id, start: $0.start, value: round($0.value, digits: digits)) }
    }

    static func rounded(_ entries: [TherapyRangeEntry], digits: Int) -> [TherapyRangeEntry] {
        entries.map { TherapyRangeEntry(id: $0.id, start: $0.start, low: round($0.low, digits: digits), high: round($0.high, digits: digits)) }
    }

    static func format(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }

    static func formatRange(_ low: Double, _ high: Double, digits: Int) -> String {
        "\(format(low, digits: digits))–\(format(high, digits: digits))"
    }

    /// A line per changed time, for the confirmation before sending: "06:00  12 → 10", "+ 14:00  9", "− 18:00".
    static func changeLines<Row: TherapyScheduleRow>(from old: [Row], to new: [Row], describe: (Row) -> String) -> [String] {
        let oldByStart = Dictionary(old.map { ($0.start, describe($0)) }, uniquingKeysWith: { first, _ in first })
        let newByStart = Dictionary(new.map { ($0.start, describe($0)) }, uniquingKeysWith: { first, _ in first })

        return Set(oldByStart.keys).union(newByStart.keys).sorted().compactMap { start in
            let time = timeString(start)
            switch (oldByStart[start], newByStart[start]) {
            case let (before?, after?) where before != after:
                return "\(time)  \(before) → \(after)"
            case let (nil, after?):
                return "+ \(time)  \(after)"
            case (_?, nil):
                return "− \(time)"
            default:
                return nil
            }
        }
    }

    static func changeLines(from old: [TherapyScheduleEntry], to new: [TherapyScheduleEntry], digits: Int) -> [String] {
        changeLines(from: old, to: new) { format($0.value, digits: digits) }
    }

    static func changeLines(from old: [TherapyRangeEntry], to new: [TherapyRangeEntry], digits: Int) -> [String] {
        changeLines(from: old, to: new) { formatRange($0.low, $0.high, digits: digits) }
    }

    static func glucoseUnitString(_ unit: HKUnit) -> String {
        unit == .milligramsPerDeciliter ? "mg/dL" : "mmol/L"
    }

    /// The v1 `therapy-settings` block: carb ratios and insulin sensitivities only. A schedule left out
    /// stays as it is in Loop. `TherapySettingsDraft.payload` builds on it for the other settings.
    static func payload(carbRatios: [TherapyScheduleEntry]?, sensitivities: [TherapyScheduleEntry]?, glucoseUnit: HKUnit) -> [String: Any] {
        var block = [String: Any]()
        if let carbRatios {
            block["carb-ratio"] = sorted(carbRatios).map { ["start": $0.start, "value": $0.value] }
        }
        if let sensitivities {
            block["insulin-sensitivity"] = sorted(sensitivities).map { ["start": $0.start, "value": $0.value] }
            block["insulin-sensitivity-unit"] = glucoseUnitString(glucoseUnit)
        }
        return block
    }
}
