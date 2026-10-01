// LoopFollow
// TherapySettingsTests.swift

import Foundation
import HealthKit
@testable import LoopFollow
import Testing

/// The `therapy-settings` block is read by Loop's NightscoutService
/// (`TherapySettingsRemoteNotification` / `TherapySettingsAction`), which is tested against the
/// same shape. Change the two together.
struct TherapySettingsTests {
    private static func entry(_ hour: Double, _ value: Double) -> TherapyScheduleEntry {
        TherapyScheduleEntry(start: Int(hour * 3600), value: value)
    }

    @Test func payloadCarriesOnlyChangedSchedules() throws {
        let payload = TherapySchedule.payload(
            carbRatios: [Self.entry(6, 10), Self.entry(0, 12)],
            sensitivities: nil,
            glucoseUnit: .millimolesPerLiter
        )

        #expect(payload["insulin-sensitivity"] == nil)
        #expect(payload["insulin-sensitivity-unit"] == nil)
        let carbRatio = try #require(payload["carb-ratio"] as? [[String: Any]])
        #expect(carbRatio.map { $0["start"] as? Int } == [0, 21600])
        #expect(carbRatio.map { $0["value"] as? Double } == [12, 10])
    }

    @Test func payloadNamesTheGlucoseUnit() throws {
        let mmol = TherapySchedule.payload(carbRatios: nil, sensitivities: [Self.entry(0, 9.5)], glucoseUnit: .millimolesPerLiter)
        #expect(mmol["insulin-sensitivity-unit"] as? String == "mmol/L")

        let mgdl = TherapySchedule.payload(carbRatios: nil, sensitivities: [Self.entry(0, 170)], glucoseUnit: .milligramsPerDeciliter)
        #expect(mgdl["insulin-sensitivity-unit"] as? String == "mg/dL")

        // It must survive the trip through JSON into the APNs body.
        let data = try JSONSerialization.data(withJSONObject: ["therapy-settings": mmol])
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect((decoded["therapy-settings"]?["insulin-sensitivity"] as? [[String: Any]])?.first?["value"] as? Double == 9.5)
    }

    @Test func scheduleMustStartAtMidnight() {
        #expect(throws: TherapySchedule.ValidationError.mustStartAtMidnight) {
            try TherapySchedule.validate([Self.entry(1, 12)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
    }

    @Test func duplicateTimesAreRejected() {
        #expect(throws: TherapySchedule.ValidationError.duplicateTime(3600)) {
            try TherapySchedule.validate([Self.entry(0, 12), Self.entry(1, 10), Self.entry(1, 11)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
    }

    @Test func valuesOutsideLoopsGuardrailsAreRejected() throws {
        // Loop: carb ratio 2–150 g/U, insulin sensitivity 9.1–500.9 mg/dL/U (≈ 0.6–27.8 mmol/L/U).
        #expect(throws: TherapySchedule.ValidationError.self) {
            try TherapySchedule.validate([Self.entry(0, 151)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
        #expect(throws: TherapySchedule.ValidationError.self) {
            try TherapySchedule.validate([Self.entry(0, 0.4)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        }
        try TherapySchedule.validate([Self.entry(0, 150), Self.entry(12, 2)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        try TherapySchedule.validate([Self.entry(0, 27.8), Self.entry(12, 0.6)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
    }

    @Test func roundedRangeNeverAllowsAValueLoopRejects() {
        let range = TherapySchedule.allowedRangeRounded(kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        let lowest = HKQuantity(unit: .millimolesPerLiter, doubleValue: range.lowerBound).doubleValue(for: .milligramsPerDeciliter)
        let highest = HKQuantity(unit: .millimolesPerLiter, doubleValue: range.upperBound).doubleValue(for: .milligramsPerDeciliter)
        #expect(lowest >= 9.1)
        #expect(highest <= 500.9)
    }

    @Test func newEntryGoesAfterTheLastAndKeepsTheValueInEffect() throws {
        let schedule = [Self.entry(0, 12), Self.entry(6, 10)]
        let added = try #require(TherapySchedule.newEntry(after: schedule))
        #expect(added.start == Int(6.5 * 3600))
        #expect(added.value == 10)
    }

    @Test func newEntryWrapsToAFreeEarlierTime() throws {
        let schedule = [Self.entry(0, 12), Self.entry(23.5, 10)]
        let added = try #require(TherapySchedule.newEntry(after: schedule))
        #expect(added.start == 1800)
        #expect(added.value == 12)
    }

    @Test func changeLinesDescribeEditsAdditionsAndRemovals() {
        let old = [Self.entry(0, 12), Self.entry(6, 10), Self.entry(18, 14)]
        let new = [Self.entry(0, 12), Self.entry(6, 9.5), Self.entry(14, 11)]
        #expect(TherapySchedule.changeLines(from: old, to: new, digits: 1).count == 3)
        #expect(TherapySchedule.changeLines(from: old, to: old, digits: 1).isEmpty)
    }

    @Test func unchangedProfileComparesEqualAfterRounding() {
        // A value converted by Loop can arrive with float noise; the editor must not see it as a change.
        let fromProfile = TherapySchedule.rounded([Self.entry(0, 9.499999)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        #expect(fromProfile == [Self.entry(0, 9.5)])
    }

    // MARK: - v2: every therapy setting

    /// A plausible toddler's settings in mmol/L, as read from Nightscout.
    private static func base(_ unit: HKUnit = .millimolesPerLiter) -> TherapySettingsDraft {
        let mmol = unit == .millimolesPerLiter
        var draft = TherapySettingsDraft(glucoseUnit: unit)
        draft.carbRatios = [entry(0, 25), entry(12, 20)]
        draft.basalRates = [entry(0, 0.3), entry(6, 0.25)]
        draft.sensitivities = [entry(0, mmol ? 10 : 180)]
        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: mmol ? 5.5 : 100, high: mmol ? 6.5 : 115)]
        draft.suspendThreshold = mmol ? 4.0 : 75
        draft.preMealRange = mmol ? 5.0 ... 5.5 : 90 ... 100
        draft.maximumBasalRate = 1.5
        draft.maximumBolus = 2
        draft.insulinModel = nil
        draft.dosingStrategy = "automaticBolus"
        draft.closedLoop = true
        draft.overridePresets = [OverridePresetDraft(name: "Sick", symbol: "🤒", duration: 0, insulinNeedsScaleFactor: 1.3)]
        return draft
    }

    @Test func unchangedDraftSendsNothing() {
        let original = Self.base()
        #expect(original.payload(from: original).isEmpty)
        #expect(original.changes(from: original).isEmpty)
        #expect(original.issues(comparedTo: original).isEmpty)
    }

    @Test func carbRatioOnlyEditKeepsTheV1Payload() throws {
        let original = Self.base()
        var draft = original
        draft.carbRatios[1].value = 18
        let payload = draft.payload(from: original)
        #expect(Set(payload.keys) == ["carb-ratio"])
        let v1 = TherapySchedule.payload(carbRatios: draft.carbRatios, sensitivities: nil, glucoseUnit: .millimolesPerLiter)
        let lhs = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        let rhs = try JSONSerialization.data(withJSONObject: v1, options: .sortedKeys)
        #expect(lhs == rhs)
    }

    @Test func sensitivityOnlyEditHasNoGlucoseUnitKey() {
        let original = Self.base()
        var draft = original
        draft.sensitivities = [Self.entry(0, 9)]
        let payload = draft.payload(from: original)
        #expect(Set(payload.keys) == ["insulin-sensitivity", "insulin-sensitivity-unit"])
        #expect(payload["glucose-unit"] == nil)
    }

    @Test func eachSettingIsSentUnderItsOwnKey() throws {
        let original = Self.base()
        func payload(_ change: (inout TherapySettingsDraft) -> Void) -> [String: Any] {
            var draft = original
            change(&draft)
            return draft.payload(from: original)
        }

        let basal = payload { $0.basalRates = [Self.entry(0, 0.35)] }
        #expect(Set(basal.keys) == ["basal-rate"])
        #expect((basal["basal-rate"] as? [[String: Any]])?.first?["value"] as? Double == 0.35)
        #expect((basal["basal-rate"] as? [[String: Any]])?.first?["start"] as? Int == 0)

        let correction = payload { $0.correctionRanges = [TherapyRangeEntry(start: 0, low: 5.0, high: 6.0), TherapyRangeEntry(start: 7200, low: 5.5, high: 7.0)] }
        #expect(Set(correction.keys) == ["correction-range", "glucose-unit"])
        let ranges = try #require(correction["correction-range"] as? [[String: Any]])
        #expect(ranges.map { $0["start"] as? Int } == [0, 7200])
        #expect(ranges.map { $0["low"] as? Double } == [5.0, 5.5])
        #expect(ranges.map { $0["high"] as? Double } == [6.0, 7.0])

        let preMeal = payload { $0.preMealRange = 4.5 ... 5.0 }
        #expect(Set(preMeal.keys) == ["pre-meal-range", "glucose-unit"])
        #expect(preMeal["pre-meal-range"] as? [String: Double] == ["low": 4.5, "high": 5.0])

        let workout = payload { $0.workoutRange = 7.0 ... 8.0 }
        #expect(Set(workout.keys) == ["workout-range", "glucose-unit"])
        #expect(workout["workout-range"] as? [String: Double] == ["low": 7.0, "high": 8.0])

        let suspend = payload { $0.suspendThreshold = 4.2 }
        #expect(Set(suspend.keys) == ["suspend-threshold", "glucose-unit"])
        #expect(suspend["suspend-threshold"] as? Double == 4.2)

        let maxBasal = payload { $0.maximumBasalRate = 1.2 }
        #expect(Set(maxBasal.keys) == ["maximum-basal-rate"])
        #expect(maxBasal["maximum-basal-rate"] as? Double == 1.2)

        let maxBolus = payload { $0.maximumBolus = 3 }
        #expect(Set(maxBolus.keys) == ["maximum-bolus"])
        #expect(maxBolus["maximum-bolus"] as? Double == 3)

        let model = payload { $0.insulinModel = "fiasp" }
        #expect(Set(model.keys) == ["insulin-model"])
        #expect(model["insulin-model"] as? String == "fiasp")

        let strategy = payload { $0.dosingStrategy = "tempBasalOnly" }
        #expect(Set(strategy.keys) == ["dosing-strategy"])
        #expect(strategy["dosing-strategy"] as? String == "tempBasalOnly")

        let closedLoop = payload { $0.closedLoop = false }
        #expect(Set(closedLoop.keys) == ["closed-loop"])
        #expect(closedLoop["closed-loop"] as? Bool == false)

        let gbpa = payload { $0.glucoseBasedPartialApplication = true }
        #expect(Set(gbpa.keys) == ["glucose-based-partial-application"])
        #expect(gbpa["glucose-based-partial-application"] as? Bool == true)

        let irc = payload { $0.integralRetrospectiveCorrection = false }
        #expect(Set(irc.keys) == ["integral-retrospective-correction"])
        #expect(irc["integral-retrospective-correction"] as? Bool == false)

        let presets = payload {
            $0.overridePresets?.append(OverridePresetDraft(name: "Run", symbol: "🏃", duration: 5400, insulinNeedsScaleFactor: 0.7, targetRange: 7.0 ... 8.0))
        }
        #expect(Set(presets.keys) == ["override-presets", "glucose-unit"])
        let sent = try #require(presets["override-presets"] as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent[0]["name"] as? String == "Sick")
        #expect(sent[0]["duration"] as? Int == 0)
        #expect(sent[0]["insulin-needs-scale-factor"] as? Double == 1.3)
        #expect(sent[0]["target-low"] == nil && sent[0]["target-high"] == nil)
        #expect(sent[1]["symbol"] as? String == "🏃")
        #expect(sent[1]["duration"] as? Int == 5400)
        #expect(sent[1]["target-low"] as? Double == 7.0)
        #expect(sent[1]["target-high"] as? Double == 8.0)

        // The whole block survives the trip into the APNs body.
        _ = try JSONSerialization.data(withJSONObject: ["therapy-settings": presets])
    }

    @Test func onlyChangedKeysAreSentTogether() {
        let original = Self.base()
        var draft = original
        draft.maximumBolus = 3
        draft.closedLoop = false
        draft.carbRatios[0].value = 22
        #expect(Set(draft.payload(from: original).keys) == ["maximum-bolus", "closed-loop", "carb-ratio"])
        #expect(TherapySettingsDraft.changedTitles(in: draft.payload(from: original)) == ["Closed Loop", "Carb Ratios", "Maximum Bolus"])
    }

    @Test func glucoseUnitFollowsTheProfile() {
        let original = Self.base(.milligramsPerDeciliter)
        var draft = original
        draft.suspendThreshold = 80
        let payload = draft.payload(from: original)
        #expect(payload["glucose-unit"] as? String == "mg/dL")
        #expect(payload["suspend-threshold"] as? Double == 80)

        let mmolOriginal = Self.base()
        var mmol = mmolOriginal
        mmol.suspendThreshold = 4.4
        #expect(mmol.payload(from: mmolOriginal)["glucose-unit"] as? String == "mmol/L")
    }

    @Test func unknownValuesAreOnlySentOncePicked() {
        let original = Self.base()
        #expect(original.workoutRange == nil && original.insulinModel == nil)
        var draft = original
        draft.maximumBolus = 2.5
        #expect(draft.payload(from: original)["workout-range"] == nil)
        #expect(draft.payload(from: original)["insulin-model"] == nil)
        draft.insulinModel = "rapidActingChild"
        #expect(draft.payload(from: original)["insulin-model"] as? String == "rapidActingChild")
    }

    @Test func insulinValuesAreSentOnThePumpsIncrement() {
        let original = Self.base()
        var draft = original
        draft.basalRates = [Self.entry(0, 0.05 * 3)]
        #expect((draft.payload(from: original)["basal-rate"] as? [[String: Any]])?.first?["value"] as? Double == 0.15)
    }

    // MARK: Guardrails

    private static func blocking(_ draft: TherapySettingsDraft, _ original: TherapySettingsDraft, _ setting: TherapySetting) -> [TherapyIssue] {
        draft.blockingIssues(comparedTo: original).filter { $0.setting == setting }
    }

    private static func warnings(_ draft: TherapySettingsDraft, _ original: TherapySettingsDraft, _ setting: TherapySetting) -> [TherapyIssue] {
        draft.issues(comparedTo: original).filter { $0.setting == setting && $0.severity == .warning }
    }

    @Test func glucoseSafetyLimitMustStayBelowEveryTargetLow() {
        let original = Self.base()
        var draft = original
        draft.suspendThreshold = 5.2 // above the pre-meal low 5.0
        #expect(!Self.blocking(draft, original, .glucoseSafetyLimit).isEmpty)
        draft.suspendThreshold = 5.0
        #expect(Self.blocking(draft, original, .glucoseSafetyLimit).isEmpty)
        // Loop's absolute 66.1–110.9 mg/dL is 3.7–6.1 mmol/L at one decimal.
        draft.suspendThreshold = 3.6
        #expect(!Self.blocking(draft, original, .glucoseSafetyLimit).isEmpty)
        draft.suspendThreshold = 3.7
        #expect(Self.blocking(draft, original, .glucoseSafetyLimit).isEmpty)
        #expect(!Self.warnings(draft, original, .glucoseSafetyLimit).isEmpty) // below the recommended 73.1 mg/dL
    }

    @Test func correctionRangeMustStayAboveTheGlucoseSafetyLimit() {
        let original = Self.base(.milligramsPerDeciliter)
        var draft = original
        draft.suspendThreshold = 95
        draft.preMealRange = 95 ... 100
        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: 90, high: 110)]
        #expect(Self.blocking(draft, original, .correctionRange).first?.message.contains("Glucose Safety Limit") == true)
        #expect(!Self.blocking(draft, original, .glucoseSafetyLimit).isEmpty)

        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: 100, high: 181)]
        #expect(!Self.blocking(draft, original, .correctionRange).isEmpty) // above 180.5
        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: 120, high: 110)]
        #expect(!Self.blocking(draft, original, .correctionRange).isEmpty) // low above high
        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: 100, high: 130)]
        #expect(Self.blocking(draft, original, .correctionRange).isEmpty)
        #expect(!Self.warnings(draft, original, .correctionRange).isEmpty) // above the recommended 115.9
    }

    @Test func preMealAndWorkoutRangesFollowLoopsOverrideGuardrails() {
        let original = Self.base(.milligramsPerDeciliter)
        var draft = original
        draft.preMealRange = 90 ... 131
        #expect(!Self.blocking(draft, original, .preMealRange).isEmpty) // pre-meal at most 130
        draft.preMealRange = 70 ... 100
        #expect(!Self.blocking(draft, original, .preMealRange).isEmpty) // below the 75 safety limit
        draft.preMealRange = 80 ... 120
        #expect(Self.blocking(draft, original, .preMealRange).isEmpty)
        #expect(!Self.warnings(draft, original, .preMealRange).isEmpty) // above the correction low

        draft = original
        draft.workoutRange = 140 ... 251
        #expect(!Self.blocking(draft, original, .workoutRange).isEmpty)
        draft.workoutRange = 85 ... 160
        #expect(!Self.blocking(draft, original, .workoutRange).isEmpty) // below 86.1
        draft.workoutRange = 140 ... 160
        #expect(draft.issues(comparedTo: original).isEmpty)
    }

    @Test func basalRatesStayWithinTheMaximumBasalRateAndPumpSteps() {
        let original = Self.base()
        var draft = original
        draft.basalRates = [Self.entry(0, 1.6)]
        #expect(Self.blocking(draft, original, .basalRate).first?.message.contains("Maximum Basal Rate") == true)
        draft.basalRates = [Self.entry(0, 0.07)]
        #expect(!Self.blocking(draft, original, .basalRate).isEmpty)
        draft.basalRates = [Self.entry(0, 0)]
        #expect(Self.blocking(draft, original, .basalRate).isEmpty) // DASH supports 0 U/h
        draft.basalRates = (0 ..< 25).map { Self.entry(Double($0) * 0.5, 0.1) }
        #expect(!Self.blocking(draft, original, .basalRate).isEmpty) // DASH holds 24 rates
    }

    @Test func maximumBasalRateFollowsBasalRatesAndCarbRatios() {
        // Highest basal 0.3 U/h, lowest carb ratio 20 g/U: 70/20 = 3.5 U/h, 6.4 × 0.3 = 1.9 U/h.
        let original = Self.base()
        let bounds = original.bounds(for: .maximumBasalRate)!
        #expect(bounds.absolute == 0.3 ... 3.5)
        #expect(bounds.recommended == 0.6 ... 1.9)

        var draft = original
        draft.maximumBasalRate = 3.55
        #expect(!Self.blocking(draft, original, .maximumBasalRate).isEmpty)
        draft.maximumBasalRate = 3.5
        #expect(Self.blocking(draft, original, .maximumBasalRate).isEmpty)
        #expect(!Self.warnings(draft, original, .maximumBasalRate).isEmpty)
        draft.maximumBasalRate = 0.25
        #expect(Self.blocking(draft, original, .maximumBasalRate).first?.message.contains("highest basal rate") == true)

        // A lower carb ratio in the same command is what Loop checks against.
        draft.maximumBasalRate = 4.5
        draft.carbRatios = [Self.entry(0, 15)]
        #expect(Self.blocking(draft, original, .maximumBasalRate).isEmpty) // 70/15 = 4.67 → 4.65
        draft.maximumBasalRate = 4.7
        #expect(!Self.blocking(draft, original, .maximumBasalRate).isEmpty)
    }

    @Test func maximumBolusFollowsLoopsGuardrail() {
        let original = Self.base()
        var draft = original
        draft.maximumBolus = 30.05
        #expect(!Self.blocking(draft, original, .maximumBolus).isEmpty)
        draft.maximumBolus = 2.02
        #expect(!Self.blocking(draft, original, .maximumBolus).isEmpty)
        draft.maximumBolus = 25
        #expect(Self.blocking(draft, original, .maximumBolus).isEmpty)
        #expect(!Self.warnings(draft, original, .maximumBolus).isEmpty)
        draft.maximumBolus = 3
        #expect(draft.issues(comparedTo: original).isEmpty)
    }

    @Test func outsideRecommendedIsAWarningNotABlock() {
        let original = Self.base()
        var draft = original
        draft.carbRatios = [Self.entry(0, 30)] // above the recommended 28
        #expect(Self.blocking(draft, original, .carbRatio).isEmpty)
        #expect(Self.warnings(draft, original, .carbRatio).count == 1)
    }

    @Test func overridePresetsAreCheckedLikeLoopsEditor() {
        let original = Self.base()
        var draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Sick", symbol: "🤧", duration: 3600, insulinNeedsScaleFactor: 1.2))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // duplicate name

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: " ", duration: 3600, insulinNeedsScaleFactor: 0.8))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // no symbol

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 3600))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // changes nothing

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 3600, insulinNeedsScaleFactor: 2.5))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // above 200 %

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 25 * 3600, insulinNeedsScaleFactor: 0.8))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // longer than 24 h

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 3600, targetRange: 3.5 ... 6.0))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // below 66.1 mg/dL

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 3600, targetRange: 7.0 ... 14.0))
        #expect(!Self.blocking(draft, original, .overridePresets).isEmpty) // above 250 mg/dL

        draft = original
        draft.overridePresets?.append(OverridePresetDraft(name: "Nap", symbol: "😴", duration: 24 * 3600, targetRange: 3.8 ... 6.0))
        #expect(Self.blocking(draft, original, .overridePresets).isEmpty)
        #expect(!Self.warnings(draft, original, .overridePresets).isEmpty) // below the 4.0 safety limit
    }

    @Test func mmolBoundsAreRoundedInward() {
        let bounds = Self.base().bounds(for: .correctionRange)!
        // 86.1–180.5 mg/dL; the safety limit 4.0 doesn't raise the 4.8 lower bound.
        #expect(bounds.absolute == 4.8 ... 10.0)
        let limits = TherapyGuardrails.limits(for: .glucoseSafetyLimit, unit: .millimolesPerLiter)!
        #expect(limits == 3.7 ... 6.1)
        #expect(TherapyGuardrails.limits(for: .glucoseSafetyLimit, unit: .milligramsPerDeciliter)! == 67 ... 110)
    }

    // MARK: Confirmation lines

    @Test func changeLinesNameEveryChangeAndHighlightRiskyOnes() throws {
        let original = Self.base()
        var draft = original
        draft.maximumBolus = 3
        draft.closedLoop = false
        draft.suspendThreshold = 3.9
        draft.maximumBasalRate = 1.0
        draft.correctionRanges = [TherapyRangeEntry(start: 0, low: 5.0, high: 6.5)]
        let changes = Dictionary(uniqueKeysWithValues: draft.changes(from: original).map { ($0.setting, $0) })

        let bolus = try #require(changes[.maximumBolus])
        #expect(bolus.lines == ["2 U → 3 U"])
        #expect(bolus.warning != nil)

        let loop = try #require(changes[.closedLoop])
        #expect(loop.lines == ["On → Off"])
        #expect(loop.warning != nil)

        let suspend = try #require(changes[.glucoseSafetyLimit])
        #expect(suspend.warning != nil)

        // Lowering the maximum basal rate is not a risk to flag.
        #expect(changes[.maximumBasalRate]?.warning == nil)

        let correction = try #require(changes[.correctionRange])
        #expect(correction.lines.count == 1)
        #expect(correction.lines[0].hasPrefix("00:00"))
        #expect(correction.lines[0].contains("→"))

        // Order follows Loop's Therapy Settings screen.
        #expect(draft.changes(from: original).map(\.setting) == [.closedLoop, .glucoseSafetyLimit, .correctionRange, .maximumBasalRate, .maximumBolus])
    }

    @Test func raisingSafetyLimitOrLoweringBolusIsNotHighlighted() {
        let original = Self.base()
        var draft = original
        draft.suspendThreshold = 4.4
        draft.maximumBolus = 1.5
        draft.closedLoop = true
        #expect(draft.changes(from: original).allSatisfy { $0.warning == nil })
    }

    @Test func presetChangeLinesDescribeEachPreset() {
        let original = Self.base()
        var draft = original
        draft.overridePresets![0].insulinNeedsScaleFactor = 1.5
        draft.overridePresets!.append(OverridePresetDraft(name: "Run", symbol: "🏃", duration: 3600, insulinNeedsScaleFactor: 0.5))
        let lines = draft.changes(from: original).first { $0.setting == .overridePresets }?.lines ?? []
        #expect(lines == ["🤒 Sick: insulin needs 130% → 150%", "+ 🏃 Run: 50%, 1 h"])

        draft = original
        draft.overridePresets = []
        #expect(draft.changes(from: original).first?.lines == ["− 🤒 Sick"])
    }

    // MARK: Reading from Nightscout

    @Test func loopSettingsAreReadFromTheProfile() throws {
        let json = """
        {"store": {"Default": {"basal": [], "sens": [], "carbratio": [], "timezone": "Europe/Oslo", "units": "mmol/L"}},
         "defaultProfile": "Default", "units": "mmol/L",
         "loopSettings": {"dosingEnabled": false, "overridePresets": [], "minimumBGGuard": 4.2,
                          "preMealTargetRange": [5.0, 5.5], "maximumBasalRatePerHour": 1.5, "maximumBolus": 2.5,
                          "dosingStrategy": "automaticBolus", "workoutTargetRange": [7.5, 8.5], "insulinModel": "fiasp",
                          "glucoseBasedApplicationFactorEnabled": true, "integralRetrospectiveCorrectionEnabled": false}}
        """
        let profile = try JSONDecoder().decode(NSProfile.self, from: Data(json.utf8))
        let settings = ProfileManager.LoopTherapySettings(profile.loopSettings)
        #expect(settings.suspendThreshold == 4.2)
        #expect(settings.preMealTargetRange == 5.0 ... 5.5)
        #expect(settings.workoutTargetRange == 7.5 ... 8.5)
        #expect(settings.maximumBasalRatePerHour == 1.5)
        #expect(settings.maximumBolus == 2.5)
        #expect(settings.dosingEnabled == false)
        #expect(settings.dosingStrategy == "automaticBolus")
        #expect(settings.insulinModel == "fiasp")
        #expect(settings.glucoseBasedApplicationFactorEnabled == true)
        #expect(settings.integralRetrospectiveCorrectionEnabled == false)
        #expect(settings.hasOverridePresets)
    }

    @Test func settingsLoopDoesNotUploadAreUnknown() throws {
        let json = """
        {"store": {"Default": {"basal": [], "sens": [], "carbratio": [], "timezone": "UTC", "units": "mg/dL"}},
         "defaultProfile": "Default", "units": "mg/dL",
         "loopSettings": {"dosingEnabled": true, "overridePresets": [], "maximumBolus": 2}}
        """
        let profile = try JSONDecoder().decode(NSProfile.self, from: Data(json.utf8))
        let settings = ProfileManager.LoopTherapySettings(profile.loopSettings)
        #expect(settings.workoutTargetRange == nil)
        #expect(settings.insulinModel == nil)
        #expect(settings.glucoseBasedApplicationFactorEnabled == nil)
        #expect(settings.integralRetrospectiveCorrectionEnabled == nil)
        #expect(ProfileManager.LoopTherapySettings(nil).hasOverridePresets == false)
    }

    @Test func correctionRangeIsBuiltFromTheLowAndHighSchedules() {
        let unit = HKUnit.millimolesPerLiter
        func values(_ pairs: [(Int, Double)]) -> [ProfileManager.TimeValue<HKQuantity>] {
            pairs.map { ProfileManager.TimeValue(timeAsSeconds: $0.0, value: HKQuantity(unit: unit, doubleValue: $0.1)) }
        }
        let ranges = TherapySchedule.rangeEntries(low: values([(0, 5.5), (21600, 5.0)]), high: values([(0, 6.5), (21600, 6.0)]), unit: unit)
        #expect(ranges == [TherapyRangeEntry(start: 0, low: 5.5, high: 6.5), TherapyRangeEntry(start: 21600, low: 5.0, high: 6.0)])
    }
}
