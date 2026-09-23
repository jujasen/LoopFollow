// LoopFollow
// TherapySchedule.swift

import Foundation
import HealthKit

/// The two Loop schedules that can be changed remotely. Basal stays a Loop-only setting.
enum TherapySettingKind: String, CaseIterable, Identifiable {
    case carbRatio
    case insulinSensitivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carbRatio: return "Carb Ratios"
        case .insulinSensitivity: return "Insulin Sensitivities"
        }
    }

    /// The unit a value is edited in. Insulin sensitivity follows the Nightscout profile's glucose unit.
    func unitLabel(glucoseUnit: HKUnit) -> String {
        switch self {
        case .carbRatio: return "g/U"
        case .insulinSensitivity: return "\(glucoseUnit.localizedShortUnitString)/U"
        }
    }

    func fractionDigits(glucoseUnit: HKUnit) -> Int {
        switch self {
        case .carbRatio: return 1
        case .insulinSensitivity: return glucoseUnit == .millimolesPerLiter ? 1 : 0
        }
    }

    /// Loop's absolute guardrails (`Guardrail.carbRatio` / `Guardrail.insulinSensitivity` in LoopKit).
    /// Loop checks them again and rejects the whole command if a value falls outside.
    func allowedRange(glucoseUnit: HKUnit) -> ClosedRange<Double> {
        switch self {
        case .carbRatio:
            return 2 ... 150
        case .insulinSensitivity:
            let lower = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 9.1).doubleValue(for: glucoseUnit)
            let upper = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 500.9).doubleValue(for: glucoseUnit)
            return lower ... upper
        }
    }
}

/// One row of a schedule: a value that applies from `start` (seconds after midnight) until the next row.
struct TherapyScheduleEntry: Identifiable, Equatable {
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

enum TherapySchedule {
    /// Loop's editors step in half hours, and allow at most one row per step.
    static let step = 30 * 60
    static let maximumEntryCount = 48
    static let day = 24 * 60 * 60

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case mustStartAtMidnight
        case duplicateTime(Int)
        case outOfRange(TherapySettingKind, Double, ClosedRange<Double>)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "The schedule needs at least one time."
            case .mustStartAtMidnight:
                return "The first time must be 00:00."
            case let .duplicateTime(start):
                return "\(TherapySchedule.timeString(start)) is used more than once."
            case let .outOfRange(_, value, range):
                return String(format: "%@ is outside what Loop allows (%@–%@).",
                              format(value), format(range.lowerBound), format(range.upperBound))
            }
        }

        private func format(_ value: Double) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter.string(from: value as NSNumber) ?? "\(value)"
        }
    }

    static func entries(from schedule: [ProfileManager.TimeValue<Double>]) -> [TherapyScheduleEntry] {
        sorted(schedule.map { TherapyScheduleEntry(start: $0.timeAsSeconds, value: $0.value) })
    }

    static func entries(from schedule: [ProfileManager.TimeValue<HKQuantity>], unit: HKUnit) -> [TherapyScheduleEntry] {
        sorted(schedule.map { TherapyScheduleEntry(start: $0.timeAsSeconds, value: $0.value.doubleValue(for: unit)) })
    }

    static func sorted(_ entries: [TherapyScheduleEntry]) -> [TherapyScheduleEntry] {
        entries.sorted { $0.start < $1.start }
    }

    static func validate(_ entries: [TherapyScheduleEntry], kind: TherapySettingKind, glucoseUnit: HKUnit) throws {
        let entries = sorted(entries)
        guard let first = entries.first else { throw ValidationError.empty }
        guard first.start == 0 else { throw ValidationError.mustStartAtMidnight }

        var seen = Set<Int>()
        for entry in entries {
            guard seen.insert(entry.start).inserted else { throw ValidationError.duplicateTime(entry.start) }
        }

        let range = allowedRangeRounded(kind: kind, glucoseUnit: glucoseUnit)
        for entry in entries where !range.contains(entry.value) {
            throw ValidationError.outOfRange(kind, entry.value, range)
        }
    }

    /// The guardrail range, narrowed to values that can be typed at the editor's precision, so a
    /// value shown as allowed here is never rejected by Loop for a rounding difference.
    static func allowedRangeRounded(kind: TherapySettingKind, glucoseUnit: HKUnit) -> ClosedRange<Double> {
        let range = kind.allowedRange(glucoseUnit: glucoseUnit)
        let scale = pow(10, Double(kind.fractionDigits(glucoseUnit: glucoseUnit)))
        return (range.lowerBound * scale).rounded(.up) / scale ... (range.upperBound * scale).rounded(.down) / scale
    }

    /// Half-hour start times not yet taken by another row.
    static func availableStarts(in entries: [TherapyScheduleEntry], keeping current: Int? = nil) -> [Int] {
        let taken = Set(entries.map(\.start)).subtracting(current.map { [$0] } ?? [])
        return stride(from: 0, to: day, by: step).filter { !taken.contains($0) }
    }

    /// A new row: the first free half hour after the last row (or the first free one at all), starting
    /// out with the value already in effect at that time, so adding a row changes nothing until edited.
    static func newEntry(after entries: [TherapyScheduleEntry]) -> TherapyScheduleEntry? {
        let entries = sorted(entries)
        guard entries.count < maximumEntryCount else { return nil }
        let free = availableStarts(in: entries)
        let lastStart = entries.last?.start ?? -1
        guard let start = free.first(where: { $0 > lastStart }) ?? free.first else { return nil }
        return TherapyScheduleEntry(start: start, value: value(at: start, in: entries) ?? 0)
    }

    static func value(at start: Int, in entries: [TherapyScheduleEntry]) -> Double? {
        sorted(entries).last(where: { $0.start <= start })?.value
    }

    static func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    /// Rounds to what the editor can show, so an unchanged schedule compares equal to the profile.
    static func rounded(_ entries: [TherapyScheduleEntry], kind: TherapySettingKind, glucoseUnit: HKUnit) -> [TherapyScheduleEntry] {
        let scale = pow(10, Double(kind.fractionDigits(glucoseUnit: glucoseUnit)))
        return entries.map { TherapyScheduleEntry(id: $0.id, start: $0.start, value: ($0.value * scale).rounded() / scale) }
    }

    /// A line per changed time, for the confirmation before sending: "06:00  12 → 10", "+ 14:00  9", "− 18:00".
    static func changeLines(from old: [TherapyScheduleEntry], to new: [TherapyScheduleEntry], digits: Int) -> [String] {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        func format(_ value: Double) -> String { formatter.string(from: value as NSNumber) ?? "\(value)" }

        let oldByStart = Dictionary(old.map { ($0.start, $0.value) }, uniquingKeysWith: { first, _ in first })
        let newByStart = Dictionary(new.map { ($0.start, $0.value) }, uniquingKeysWith: { first, _ in first })

        return Set(oldByStart.keys).union(newByStart.keys).sorted().compactMap { start in
            let time = timeString(start)
            switch (oldByStart[start], newByStart[start]) {
            case let (before?, after?) where before != after:
                return "\(time)  \(format(before)) → \(format(after))"
            case let (nil, after?):
                return "+ \(time)  \(format(after))"
            case (_?, nil):
                return "− \(time)"
            default:
                return nil
            }
        }
    }

    /// The `therapy-settings` block Loop's NightscoutService reads. A schedule left out stays as it is in Loop.
    static func payload(carbRatios: [TherapyScheduleEntry]?, sensitivities: [TherapyScheduleEntry]?, glucoseUnit: HKUnit) -> [String: Any] {
        var block = [String: Any]()
        if let carbRatios {
            block["carb-ratio"] = sorted(carbRatios).map { ["start": $0.start, "value": $0.value] }
        }
        if let sensitivities {
            block["insulin-sensitivity"] = sorted(sensitivities).map { ["start": $0.start, "value": $0.value] }
            block["insulin-sensitivity-unit"] = glucoseUnit == .milligramsPerDeciliter ? "mg/dL" : "mmol/L"
        }
        return block
    }
}
