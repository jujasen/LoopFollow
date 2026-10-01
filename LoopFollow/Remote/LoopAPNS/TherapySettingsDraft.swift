// LoopFollow
// TherapySettingsDraft.swift

import Foundation
import HealthKit

/// Every Loop therapy setting the `therapy-settings` command can change, in the order of Loop's own
/// Therapy Settings screen.
enum TherapySetting: String, CaseIterable, Identifiable {
    case closedLoop
    case dosingStrategy
    case glucoseSafetyLimit
    case correctionRange
    case preMealRange
    case workoutRange
    case carbRatio
    case basalRate
    case maximumBasalRate
    case maximumBolus
    case insulinSensitivity
    case insulinModel
    case overridePresets
    case glucoseBasedPartialApplication
    case integralRetrospectiveCorrection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closedLoop: return "Closed Loop"
        case .dosingStrategy: return "Dosing Strategy"
        case .glucoseSafetyLimit: return "Glucose Safety Limit"
        case .correctionRange: return "Correction Range"
        case .preMealRange: return "Pre-Meal Range"
        case .workoutRange: return "Workout Range"
        case .carbRatio: return "Carb Ratios"
        case .basalRate: return "Basal Rates"
        case .maximumBasalRate: return "Maximum Basal Rate"
        case .maximumBolus: return "Maximum Bolus"
        case .insulinSensitivity: return "Insulin Sensitivities"
        case .insulinModel: return "Insulin Model"
        case .overridePresets: return "Override Presets"
        case .glucoseBasedPartialApplication: return "Glucose Based Partial Application"
        case .integralRetrospectiveCorrection: return "Integral Retrospective Correction"
        }
    }

    /// The `therapy-settings` keys this setting is sent as.
    var payloadKey: String {
        switch self {
        case .closedLoop: return "closed-loop"
        case .dosingStrategy: return "dosing-strategy"
        case .glucoseSafetyLimit: return "suspend-threshold"
        case .correctionRange: return "correction-range"
        case .preMealRange: return "pre-meal-range"
        case .workoutRange: return "workout-range"
        case .carbRatio: return "carb-ratio"
        case .basalRate: return "basal-rate"
        case .maximumBasalRate: return "maximum-basal-rate"
        case .maximumBolus: return "maximum-bolus"
        case .insulinSensitivity: return "insulin-sensitivity"
        case .insulinModel: return "insulin-model"
        case .overridePresets: return "override-presets"
        case .glucoseBasedPartialApplication: return "glucose-based-partial-application"
        case .integralRetrospectiveCorrection: return "integral-retrospective-correction"
        }
    }

    /// Settings whose values are glucose amounts, sent in `glucose-unit`. Insulin sensitivity keeps
    /// its own v1 `insulin-sensitivity-unit`.
    var carriesGlucose: Bool {
        switch self {
        case .glucoseSafetyLimit, .correctionRange, .preMealRange, .workoutRange, .overridePresets: return true
        default: return false
        }
    }
}

enum InsulinModelOption: String, CaseIterable, Identifiable {
    case rapidActingAdult
    case rapidActingChild
    case fiasp
    case lyumjev
    case afrezza

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rapidActingAdult: return "Rapid-Acting – Adults"
        case .rapidActingChild: return "Rapid-Acting – Children"
        case .fiasp: return "Fiasp"
        case .lyumjev: return "Lyumjev"
        case .afrezza: return "Afrezza"
        }
    }

    /// Afrezza is inhaled and hidden in Loop's own picker unless enabled; it is offered only when Loop
    /// already uses it.
    static let selectable: [InsulinModelOption] = [.rapidActingAdult, .rapidActingChild, .fiasp, .lyumjev]

    static func title(for rawValue: String?) -> String {
        guard let rawValue else { return "Unknown" }
        return InsulinModelOption(rawValue: rawValue)?.title ?? rawValue
    }
}

enum DosingStrategyOption: String, CaseIterable, Identifiable {
    case tempBasalOnly
    case automaticBolus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tempBasalOnly: return "Temp Basal Only"
        case .automaticBolus: return "Automatic Bolus"
        }
    }

    static func title(for rawValue: String?) -> String {
        guard let rawValue else { return "Unknown" }
        return DosingStrategyOption(rawValue: rawValue)?.title ?? rawValue
    }
}

/// A Loop override preset as edited here. Loop replaces its whole preset list with the one sent, and
/// keeps the identity of a preset whose name it already has.
struct OverridePresetDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var symbol: String
    /// Seconds; 0 is indefinite, as in Loop's Nightscout upload.
    var duration: Int
    var insulinNeedsScaleFactor: Double
    /// In the draft's glucose unit; nil keeps Loop's correction range.
    var targetRange: ClosedRange<Double>?

    init(id: UUID = UUID(), name: String, symbol: String, duration: Int, insulinNeedsScaleFactor: Double = 1, targetRange: ClosedRange<Double>? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.duration = duration
        self.insulinNeedsScaleFactor = insulinNeedsScaleFactor
        self.targetRange = targetRange
    }

    /// The identity is local to this screen; two lists with the same presets in the same order are equal.
    static func == (lhs: OverridePresetDraft, rhs: OverridePresetDraft) -> Bool {
        lhs.name == rhs.name && lhs.symbol == rhs.symbol && lhs.duration == rhs.duration
            && lhs.insulinNeedsScaleFactor == rhs.insulinNeedsScaleFactor && lhs.targetRange == rhs.targetRange
    }

    var insulinNeedsPercent: Int { Int((insulinNeedsScaleFactor * 100).rounded()) }

    static func durationString(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Indefinite" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(minutes) min"
        }
    }

    func summary(glucoseUnit: HKUnit) -> String {
        var parts = ["\(insulinNeedsPercent)%"]
        if let targetRange {
            let digits = TherapyGuardrails.glucoseDigits(glucoseUnit)
            parts.append(TherapySchedule.formatRange(targetRange.lowerBound, targetRange.upperBound, digits: digits) + " " + glucoseUnit.localizedShortUnitString)
        }
        parts.append(Self.durationString(duration))
        return parts.joined(separator: ", ")
    }
}

/// A problem with a value about to be sent. A blocking issue is something Loop rejects; a warning is
/// a value outside Loop's recommended bounds, which Loop's own editors also only warn about.
struct TherapyIssue: Equatable, Identifiable {
    enum Severity: Equatable {
        case blocking
        case warning
    }

    let setting: TherapySetting
    let severity: Severity
    let message: String

    var id: String { "\(setting.rawValue)|\(message)" }
}

/// One setting's lines in the confirmation before sending.
struct TherapyChange: Equatable, Identifiable {
    let setting: TherapySetting
    let lines: [String]
    /// A change that deserves a second look, shown highlighted.
    let warning: String?

    var id: String { setting.rawValue }
}

/// All of Loop's therapy settings as read from Nightscout, and as edited. nil (or an empty schedule)
/// is a value Nightscout does not show; it is only sent once a value has been picked.
struct TherapySettingsDraft: Equatable {
    var glucoseUnit: HKUnit
    var carbRatios: [TherapyScheduleEntry] = []
    var basalRates: [TherapyScheduleEntry] = []
    var sensitivities: [TherapyScheduleEntry] = []
    var correctionRanges: [TherapyRangeEntry] = []
    var suspendThreshold: Double?
    var preMealRange: ClosedRange<Double>?
    var workoutRange: ClosedRange<Double>?
    var maximumBasalRate: Double?
    var maximumBolus: Double?
    var insulinModel: String?
    var dosingStrategy: String?
    var closedLoop: Bool?
    var overridePresets: [OverridePresetDraft]?
    var glucoseBasedPartialApplication: Bool?
    var integralRetrospectiveCorrection: Bool?

    var glucoseDigits: Int { TherapyGuardrails.glucoseDigits(glucoseUnit) }
    var glucoseUnitLabel: String { glucoseUnit.localizedShortUnitString }

    // MARK: - Reading from Nightscout

    /// The settings in Loop's last Nightscout profile, rounded to what the editors show, so an
    /// untouched value compares equal and is never sent.
    static func fromProfile(_ profile: ProfileManager = .shared) -> TherapySettingsDraft {
        let unit = profile.units
        let loop = profile.loopTherapySettings
        let digits = TherapyGuardrails.glucoseDigits(unit)
        func glucose(_ value: Double?) -> Double? { value.map { TherapySchedule.round($0, digits: digits) } }
        func glucose(_ range: ClosedRange<Double>?) -> ClosedRange<Double>? {
            range.map { TherapySchedule.round($0.lowerBound, digits: digits) ... TherapySchedule.round($0.upperBound, digits: digits) }
        }

        var draft = TherapySettingsDraft(glucoseUnit: unit)
        draft.carbRatios = TherapySchedule.rounded(TherapySchedule.entries(from: profile.carbRatioSchedule), kind: .carbRatio, glucoseUnit: unit)
        draft.basalRates = TherapySchedule.rounded(TherapySchedule.entries(from: profile.basalSchedule), kind: .basalRate, glucoseUnit: unit)
        draft.sensitivities = TherapySchedule.rounded(TherapySchedule.entries(from: profile.isfSchedule, unit: unit), kind: .insulinSensitivity, glucoseUnit: unit)
        draft.correctionRanges = TherapySchedule.rounded(
            TherapySchedule.rangeEntries(low: profile.targetLowSchedule, high: profile.targetHighSchedule, unit: unit),
            digits: digits
        )
        draft.suspendThreshold = glucose(loop.suspendThreshold)
        draft.preMealRange = glucose(loop.preMealTargetRange)
        draft.workoutRange = glucose(loop.workoutTargetRange)
        draft.maximumBasalRate = loop.maximumBasalRatePerHour.map { TherapySchedule.round($0, digits: 3) }
        draft.maximumBolus = loop.maximumBolus.map { TherapySchedule.round($0, digits: 3) }
        draft.insulinModel = loop.insulinModel
        draft.dosingStrategy = loop.dosingStrategy
        draft.closedLoop = loop.dosingEnabled
        draft.glucoseBasedPartialApplication = loop.glucoseBasedApplicationFactorEnabled
        draft.integralRetrospectiveCorrection = loop.integralRetrospectiveCorrectionEnabled
        if loop.hasOverridePresets {
            draft.overridePresets = profile.loopOverrides.map { preset in
                let range = preset.targetRange.count == 2
                    ? glucose(preset.targetRange[0].doubleValue(for: unit) ... max(preset.targetRange[0].doubleValue(for: unit), preset.targetRange[1].doubleValue(for: unit)))
                    : nil
                return OverridePresetDraft(
                    name: preset.name,
                    symbol: preset.symbol,
                    duration: max(0, preset.duration ?? 0),
                    insulinNeedsScaleFactor: TherapySchedule.round(preset.insulinNeedsScaleFactor, digits: 2),
                    targetRange: range
                )
            }
        }
        return draft
    }

    // MARK: - Changes

    func isChanged(_ setting: TherapySetting, from original: TherapySettingsDraft) -> Bool {
        switch setting {
        case .closedLoop: return closedLoop != original.closedLoop
        case .dosingStrategy: return dosingStrategy != original.dosingStrategy
        case .glucoseSafetyLimit: return suspendThreshold != original.suspendThreshold
        case .correctionRange: return correctionRanges != original.correctionRanges
        case .preMealRange: return preMealRange != original.preMealRange
        case .workoutRange: return workoutRange != original.workoutRange
        case .carbRatio: return carbRatios != original.carbRatios
        case .basalRate: return basalRates != original.basalRates
        case .maximumBasalRate: return maximumBasalRate != original.maximumBasalRate
        case .maximumBolus: return maximumBolus != original.maximumBolus
        case .insulinSensitivity: return sensitivities != original.sensitivities
        case .insulinModel: return insulinModel != original.insulinModel
        case .overridePresets: return overridePresets != original.overridePresets
        case .glucoseBasedPartialApplication: return glucoseBasedPartialApplication != original.glucoseBasedPartialApplication
        case .integralRetrospectiveCorrection: return integralRetrospectiveCorrection != original.integralRetrospectiveCorrection
        }
    }

    func changedSettings(from original: TherapySettingsDraft) -> [TherapySetting] {
        TherapySetting.allCases.filter { isChanged($0, from: original) }
    }

    // MARK: - Payload

    /// The `therapy-settings` block: only the settings that changed. Carb ratios and insulin
    /// sensitivities are sent exactly as in v1; `glucose-unit` is present exactly when a glucose
    /// setting is.
    func payload(from original: TherapySettingsDraft) -> [String: Any] {
        let changed = Set(changedSettings(from: original))
        var block = TherapySchedule.payload(
            carbRatios: changed.contains(.carbRatio) ? carbRatios : nil,
            sensitivities: changed.contains(.insulinSensitivity) ? sensitivities : nil,
            glucoseUnit: glucoseUnit
        )
        func put(_ setting: TherapySetting, _ value: Any?) {
            guard changed.contains(setting), let value else { return }
            block[setting.payloadKey] = value
        }
        func range(_ range: ClosedRange<Double>?) -> [String: Double]? {
            range.map { ["low": $0.lowerBound, "high": $0.upperBound] }
        }

        put(.basalRate, basalRates.isEmpty ? nil : TherapySchedule.sorted(basalRates).map {
            ["start": $0.start, "value": TherapyGuardrails.roundedToIncrement($0.value)] as [String: Any]
        })
        put(.correctionRange, correctionRanges.isEmpty ? nil : TherapySchedule.sorted(correctionRanges).map {
            ["start": $0.start, "low": $0.low, "high": $0.high] as [String: Any]
        })
        put(.preMealRange, range(preMealRange))
        put(.workoutRange, range(workoutRange))
        put(.glucoseSafetyLimit, suspendThreshold)
        put(.maximumBasalRate, maximumBasalRate.map(TherapyGuardrails.roundedToIncrement))
        put(.maximumBolus, maximumBolus.map(TherapyGuardrails.roundedToIncrement))
        put(.insulinModel, insulinModel)
        put(.dosingStrategy, dosingStrategy)
        put(.closedLoop, closedLoop)
        put(.overridePresets, overridePresets?.map { preset -> [String: Any] in
            var entry: [String: Any] = [
                "name": preset.name.trimmingCharacters(in: .whitespacesAndNewlines),
                "symbol": preset.symbol.trimmingCharacters(in: .whitespacesAndNewlines),
                "duration": preset.duration,
                "insulin-needs-scale-factor": preset.insulinNeedsScaleFactor,
            ]
            if let target = preset.targetRange {
                entry["target-low"] = target.lowerBound
                entry["target-high"] = target.upperBound
            }
            return entry
        })
        put(.glucoseBasedPartialApplication, glucoseBasedPartialApplication)
        put(.integralRetrospectiveCorrection, integralRetrospectiveCorrection)

        if TherapySetting.allCases.contains(where: { $0.carriesGlucose && block[$0.payloadKey] != nil }) {
            block["glucose-unit"] = TherapySchedule.glucoseUnitString(glucoseUnit)
        }
        return block
    }

    /// Names for the notification Loop shows, from a payload's keys: "Carb Ratios and Insulin Sensitivities".
    static func changedTitles(in payload: [String: Any]) -> [String] {
        TherapySetting.allCases.filter { payload[$0.payloadKey] != nil }.map(\.title)
    }

    // MARK: - Confirmation lines

    func changes(from original: TherapySettingsDraft) -> [TherapyChange] {
        let g = glucoseDigits
        let gUnit = glucoseUnitLabel
        func glucose(_ value: Double?) -> String { value.map { TherapySchedule.format($0, digits: g) + " " + gUnit } ?? "Unknown" }
        func glucoseRange(_ range: ClosedRange<Double>?) -> String {
            range.map { TherapySchedule.formatRange($0.lowerBound, $0.upperBound, digits: g) + " " + gUnit } ?? "Unknown"
        }
        func insulin(_ value: Double?, _ unit: String) -> String { value.map { TherapySchedule.format($0, digits: 3) + " " + unit } ?? "Unknown" }
        func onOff(_ value: Bool?) -> String { value.map { $0 ? "On" : "Off" } ?? "Unknown" }
        func line<T>(_ old: T, _ new: T, _ describe: (T) -> String) -> [String] { ["\(describe(old)) → \(describe(new))"] }

        return changedSettings(from: original).map { setting in
            switch setting {
            case .closedLoop:
                return TherapyChange(setting: setting, lines: line(original.closedLoop, closedLoop, onOff),
                                     warning: closedLoop == false ? "Loop stops dosing automatically. It only gives insulin that is bolused by hand." : nil)
            case .dosingStrategy:
                return TherapyChange(setting: setting, lines: line(original.dosingStrategy, dosingStrategy, DosingStrategyOption.title), warning: nil)
            case .glucoseSafetyLimit:
                let lowered = (suspendThreshold ?? 0) < (original.suspendThreshold ?? .infinity)
                return TherapyChange(setting: setting, lines: line(original.suspendThreshold, suspendThreshold, glucose),
                                     warning: lowered ? "A lower Glucose Safety Limit lets Loop keep giving insulin at lower glucose." : nil)
            case .correctionRange:
                return TherapyChange(setting: setting, lines: scheduleLines(TherapySchedule.changeLines(from: original.correctionRanges, to: correctionRanges, digits: g), unit: gUnit), warning: nil)
            case .preMealRange:
                return TherapyChange(setting: setting, lines: line(original.preMealRange, preMealRange, glucoseRange), warning: nil)
            case .workoutRange:
                return TherapyChange(setting: setting, lines: line(original.workoutRange, workoutRange, glucoseRange), warning: nil)
            case .carbRatio, .basalRate, .insulinSensitivity:
                let kind: TherapySettingKind = setting == .carbRatio ? .carbRatio : setting == .basalRate ? .basalRate : .insulinSensitivity
                let lines = TherapySchedule.changeLines(from: original.entries(for: kind), to: entries(for: kind), digits: kind.fractionDigits(glucoseUnit: glucoseUnit))
                return TherapyChange(setting: setting, lines: scheduleLines(lines, unit: kind.unitLabel(glucoseUnit: glucoseUnit)), warning: nil)
            case .maximumBasalRate:
                let raised = (maximumBasalRate ?? 0) > (original.maximumBasalRate ?? -.infinity)
                return TherapyChange(setting: setting, lines: line(original.maximumBasalRate, maximumBasalRate) { insulin($0, "U/h") },
                                     warning: raised ? "A higher Maximum Basal Rate lets Loop give more insulin through temp basals." : nil)
            case .maximumBolus:
                let raised = (maximumBolus ?? 0) > (original.maximumBolus ?? -.infinity)
                return TherapyChange(setting: setting, lines: line(original.maximumBolus, maximumBolus) { insulin($0, "U") },
                                     warning: raised ? "A higher Maximum Bolus allows larger boluses, also automatic ones." : nil)
            case .insulinModel:
                return TherapyChange(setting: setting, lines: line(original.insulinModel, insulinModel, InsulinModelOption.title), warning: nil)
            case .overridePresets:
                return TherapyChange(setting: setting, lines: presetChangeLines(from: original.overridePresets ?? []), warning: nil)
            case .glucoseBasedPartialApplication:
                return TherapyChange(setting: setting, lines: line(original.glucoseBasedPartialApplication, glucoseBasedPartialApplication, onOff), warning: nil)
            case .integralRetrospectiveCorrection:
                return TherapyChange(setting: setting, lines: line(original.integralRetrospectiveCorrection, integralRetrospectiveCorrection, onOff), warning: nil)
            }
        }
    }

    private func scheduleLines(_ lines: [String], unit: String) -> [String] {
        // Times can be reordered without changing a value, which leaves nothing to list.
        lines.isEmpty ? ["Times changed"] : lines.map { $0.hasPrefix("−") ? $0 : "\($0) \(unit)" }
    }

    private func presetChangeLines(from old: [OverridePresetDraft]) -> [String] {
        let new = overridePresets ?? []
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var lines = [String]()

        for preset in old where !newIDs.contains(preset.id) {
            lines.append("− \(preset.symbol) \(preset.name)")
        }
        for preset in new {
            guard let before = oldByID[preset.id] else {
                lines.append("+ \(preset.symbol) \(preset.name): \(preset.summary(glucoseUnit: glucoseUnit))")
                continue
            }
            guard before != preset else { continue }
            var parts = [String]()
            if before.name != preset.name { parts.append("name \(before.name) → \(preset.name)") }
            if before.symbol != preset.symbol { parts.append("symbol \(before.symbol) → \(preset.symbol)") }
            if before.insulinNeedsScaleFactor != preset.insulinNeedsScaleFactor {
                parts.append("insulin needs \(before.insulinNeedsPercent)% → \(preset.insulinNeedsPercent)%")
            }
            if before.targetRange != preset.targetRange {
                func target(_ range: ClosedRange<Double>?) -> String {
                    range.map { TherapySchedule.formatRange($0.lowerBound, $0.upperBound, digits: glucoseDigits) + " " + glucoseUnitLabel } ?? "Correction Range"
                }
                parts.append("target \(target(before.targetRange)) → \(target(preset.targetRange))")
            }
            if before.duration != preset.duration {
                parts.append("duration \(OverridePresetDraft.durationString(before.duration)) → \(OverridePresetDraft.durationString(preset.duration))")
            }
            lines.append("\(preset.symbol) \(preset.name): " + parts.joined(separator: ", "))
        }
        if lines.isEmpty { lines.append("Order changed") }
        return lines
    }

    func entries(for kind: TherapySettingKind) -> [TherapyScheduleEntry] {
        switch kind {
        case .carbRatio: return carbRatios
        case .basalRate: return basalRates
        case .insulinSensitivity: return sensitivities
        }
    }

    mutating func setEntries(_ entries: [TherapyScheduleEntry], for kind: TherapySettingKind) {
        switch kind {
        case .carbRatio: carbRatios = entries
        case .basalRate: basalRates = entries
        case .insulinSensitivity: sensitivities = entries
        }
    }
}
