// LoopFollow
// TherapyGuardrails.swift

import Foundation
import HealthKit

/// Loop's guardrails (LoopKit `Guardrail+Settings.swift`) for an Omnipod DASH, in the draft's glucose
/// unit. Absolute bounds are what Loop's editors allow at all, and what Loop's remote command checks
/// against the resulting settings; a single value outside rejects the whole command. Recommended
/// bounds only earn a warning, as they do in Loop.
struct TherapyBounds: Equatable {
    let absolute: ClosedRange<Double>
    let recommended: ClosedRange<Double>
}

enum TherapyGuardrails {
    /// Omnipod DASH delivers basal and bolus in 0.05 U steps; 0 U/h is a supported scheduled basal rate.
    static let pumpIncrement = 0.05
    static let supportedBasalRates: ClosedRange<Double> = 0 ... 30
    static let supportedBolusVolumes: ClosedRange<Double> = 0.05 ... 30
    static let maximumBasalScheduleEntryCount = 24

    // In mg/dL, as in LoopKit.
    static let suspendThresholdAbsolute = 66.1 ... 110.9
    static let suspendThresholdRecommended = 73.1 ... 80.9
    static let correctionRangeAbsolute = 86.1 ... 180.5
    static let correctionRangeRecommended = 99.1 ... 115.9
    static let preMealMaximum = 130.0
    static let workoutMaximum = 250.0
    static let workoutRecommendedMaximum = 180.0
    /// Loop's override preset editor offers 10 % to 200 % in 10 % steps.
    static let insulinNeedsScaleFactors = 0.1 ... 2.0
    /// Loop's editor takes any preset target; its remote command holds one to the widest range any of
    /// Loop's glucose editors allow, from the lowest glucose safety limit to the highest workout target.
    static let overrideTargetAbsolute = 66.1 ... 250.0
    /// `LoopConstants.maxOverrideDurationTime`.
    static let maximumOverrideDuration = 24 * 60 * 60

    static func overrideTargetLimits(unit: HKUnit) -> ClosedRange<Double> {
        TherapySchedule.roundedInward(convert(overrideTargetAbsolute, to: unit), digits: glucoseDigits(unit))
    }

    static func glucoseDigits(_ unit: HKUnit) -> Int {
        unit == .millimolesPerLiter ? 1 : 0
    }

    static func convert(_ mgdl: Double, to unit: HKUnit) -> Double {
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl).doubleValue(for: unit)
    }

    static func convert(_ range: ClosedRange<Double>, to unit: HKUnit) -> ClosedRange<Double> {
        convert(range.lowerBound, to: unit) ... convert(range.upperBound, to: unit)
    }

    static func isMultiple(_ value: Double, of increment: Double) -> Bool {
        let steps = value / increment
        return abs(steps.rounded() - steps) < 1e-6
    }

    static func roundedToIncrement(_ value: Double) -> Double {
        TherapySchedule.round((value / pumpIncrement).rounded() * pumpIncrement, digits: 3)
    }

    /// `matchingOrTruncatedValue(from: supportedBasalRates, withinDecimalPlaces: 3)`.
    static func supportedBasalRate(matchingOrTruncating value: Double) -> Double {
        let clamped = min(max(value, supportedBasalRates.lowerBound), supportedBasalRates.upperBound)
        let nearest = roundedToIncrement(clamped)
        if abs(nearest - value) <= 0.001 { return nearest }
        return TherapySchedule.round((clamped / pumpIncrement + 1e-9).rounded(.down) * pumpIncrement, digits: 3)
    }

    /// Absolute bounds are narrowed to the editor's precision (so a typed value Loop could reject for
    /// a rounding difference is not allowed); recommended bounds are compared as they are.
    private static func glucoseBounds(absolute: ClosedRange<Double>, recommended: ClosedRange<Double>, unit: HKUnit) -> TherapyBounds {
        let absolute = TherapySchedule.roundedInward(absolute, digits: glucoseDigits(unit))
        return TherapyBounds(absolute: absolute, recommended: recommended.clamped(to: absolute))
    }

    // MARK: - Glucose settings (inputs in `unit`)

    /// `Guardrail.suspendThreshold`, capped by `maxSuspendThresholdValue`: no higher than the lowest
    /// correction range, pre-meal or workout low.
    static func suspendThreshold(unit: HKUnit, correctionRanges: [TherapyRangeEntry], preMealRange: ClosedRange<Double>?, workoutRange: ClosedRange<Double>?) -> TherapyBounds {
        let absolute = convert(suspendThresholdAbsolute, to: unit)
        let upper = ([absolute.upperBound, correctionRanges.map(\.low).min(), preMealRange?.lowerBound, workoutRange?.lowerBound] as [Double?])
            .compactMap { $0 }.min()!
        return glucoseBounds(absolute: absolute.lowerBound ... max(absolute.lowerBound, upper), recommended: convert(suspendThresholdRecommended, to: unit), unit: unit)
    }

    /// `Guardrail.correctionRange`, with the lower bound raised by `minCorrectionRangeValue` to the
    /// glucose safety limit.
    static func correctionRange(unit: HKUnit, suspendThreshold: Double?) -> TherapyBounds {
        let absolute = convert(correctionRangeAbsolute, to: unit)
        let lower = max(absolute.lowerBound, suspendThreshold ?? -.infinity)
        return glucoseBounds(absolute: lower ... max(lower, absolute.upperBound), recommended: convert(correctionRangeRecommended, to: unit), unit: unit)
    }

    /// `Guardrail.correctionRangeOverride(for: .preMeal, ...)`.
    static func preMealRange(unit: HKUnit, correctionRanges: [TherapyRangeEntry], suspendThreshold: Double?) -> TherapyBounds {
        let lower = suspendThreshold ?? convert(suspendThresholdAbsolute.lowerBound, to: unit)
        let upper = convert(preMealMaximum, to: unit)
        let scheduleLow = correctionRanges.map(\.low).min() ?? upper
        let recommendedUpper = min(max(lower, scheduleLow), upper)
        return glucoseBounds(absolute: lower ... max(lower, upper), recommended: lower ... recommendedUpper, unit: unit)
    }

    /// `Guardrail.correctionRangeOverride(for: .workout, ...)`.
    static func workoutRange(unit: HKUnit, correctionRanges: [TherapyRangeEntry], suspendThreshold: Double?) -> TherapyBounds {
        let lower = max(convert(correctionRangeAbsolute.lowerBound, to: unit), suspendThreshold ?? -.infinity)
        let upper = convert(workoutMaximum, to: unit)
        let recommendedLower = max(lower, correctionRanges.map(\.high).max() ?? lower)
        let recommendedUpper = max(recommendedLower, convert(workoutRecommendedMaximum, to: unit))
        return glucoseBounds(absolute: lower ... max(lower, upper), recommended: recommendedLower ... recommendedUpper, unit: unit)
    }

    // MARK: - Delivery limits

    /// `Guardrail.maximumBasalRate(supportedBasalRates:scheduledBasalRange:lowestCarbRatio:)`.
    static func maximumBasalRate(basalRates: [Double], carbRatios: [Double]) -> TherapyBounds {
        let lowestCarbRatio = carbRatios.min() ?? 2
        let absoluteUpper = supportedBasalRate(matchingOrTruncating: 70 / lowestCarbRatio)

        if let highest = basalRates.max() {
            let recommendedLower = supportedBasalRate(matchingOrTruncating: 2.1 * highest)
            let recommendedUpper = supportedBasalRate(matchingOrTruncating: 6.4 * highest)
            let absolute = highest ... max(absoluteUpper, recommendedUpper)
            return TherapyBounds(absolute: absolute, recommended: (recommendedLower ... recommendedUpper).clamped(to: absolute))
        } else {
            let absolute = pumpIncrement ... max(pumpIncrement, absoluteUpper)
            return TherapyBounds(absolute: absolute, recommended: absolute)
        }
    }

    /// `Guardrail.maximumBolus(supportedBolusVolumes:)`: up to 30 U, recommended below 20 U.
    static let maximumBolus = TherapyBounds(absolute: supportedBolusVolumes, recommended: 0.1 ... 19.95)
}

// MARK: - Validation

extension TherapySettingsDraft {
    func bounds(for setting: TherapySetting) -> TherapyBounds? {
        switch setting {
        case .glucoseSafetyLimit:
            return TherapyGuardrails.suspendThreshold(unit: glucoseUnit, correctionRanges: correctionRanges, preMealRange: preMealRange, workoutRange: workoutRange)
        case .correctionRange:
            return TherapyGuardrails.correctionRange(unit: glucoseUnit, suspendThreshold: suspendThreshold)
        case .preMealRange:
            return TherapyGuardrails.preMealRange(unit: glucoseUnit, correctionRanges: correctionRanges, suspendThreshold: suspendThreshold)
        case .workoutRange:
            return TherapyGuardrails.workoutRange(unit: glucoseUnit, correctionRanges: correctionRanges, suspendThreshold: suspendThreshold)
        case .maximumBasalRate:
            return TherapyGuardrails.maximumBasalRate(basalRates: basalRates.map(\.value), carbRatios: carbRatios.map(\.value))
        case .maximumBolus:
            return TherapyGuardrails.maximumBolus
        case .carbRatio, .basalRate, .insulinSensitivity:
            let kind: TherapySettingKind = setting == .carbRatio ? .carbRatio : setting == .basalRate ? .basalRate : .insulinSensitivity
            var absolute = TherapySchedule.allowedRangeRounded(kind: kind, glucoseUnit: glucoseUnit)
            if kind == .basalRate, let maximumBasalRate {
                absolute = absolute.lowerBound ... max(absolute.lowerBound, min(absolute.upperBound, maximumBasalRate))
            }
            return TherapyBounds(absolute: absolute, recommended: kind.recommendedRange(glucoseUnit: glucoseUnit).clamped(to: absolute))
        default:
            return nil
        }
    }

    /// Everything wrong with the changed settings, checked against the resulting settings (the
    /// current ones with every change applied), as Loop does. Settings left alone are not checked:
    /// Loop doesn't check them either.
    func issues(comparedTo original: TherapySettingsDraft) -> [TherapyIssue] {
        var seen = Set<String>()
        return changedSettings(from: original)
            .flatMap { issues(for: $0, original: original) }
            .filter { seen.insert($0.id).inserted }
    }

    func blockingIssues(comparedTo original: TherapySettingsDraft) -> [TherapyIssue] {
        issues(comparedTo: original).filter { $0.severity == .blocking }
    }

    private func issues(for setting: TherapySetting, original: TherapySettingsDraft) -> [TherapyIssue] {
        var issues = [TherapyIssue]()
        func block(_ message: String) { issues.append(TherapyIssue(setting: setting, severity: .blocking, message: message)) }
        func warn(_ message: String) { issues.append(TherapyIssue(setting: setting, severity: .warning, message: message)) }

        let g = glucoseDigits
        let gUnit = glucoseUnitLabel
        func glucose(_ value: Double) -> String { TherapySchedule.format(value, digits: g) + " " + gUnit }
        func glucoseRange(_ range: ClosedRange<Double>) -> String {
            TherapySchedule.formatRange(range.lowerBound, range.upperBound, digits: g) + " " + gUnit
        }
        func insulin(_ value: Double, _ unit: String) -> String { TherapySchedule.format(value, digits: 3) + " " + unit }
        func insulinRange(_ range: ClosedRange<Double>, _ unit: String) -> String {
            TherapySchedule.formatRange(range.lowerBound, range.upperBound, digits: 3) + " " + unit
        }

        /// Checks one glucose value (prefixed with a time or a "Low"/"High" label) against bounds,
        /// naming the cross-setting limit when that is what it breaks.
        func checkGlucose(_ value: Double, label: String, bounds: TherapyBounds, lowerReason: String? = nil, upperReason: String? = nil) {
            let prefix = label.isEmpty ? "" : "\(label): "
            if value < bounds.absolute.lowerBound {
                block("\(prefix)\(glucose(value)) is below " + (lowerReason ?? "what Loop allows") + " (\(glucose(bounds.absolute.lowerBound))).")
            } else if value > bounds.absolute.upperBound {
                block("\(prefix)\(glucose(value)) is above " + (upperReason ?? "what Loop allows") + " (\(glucose(bounds.absolute.upperBound))).")
            } else if !bounds.recommended.contains(value) {
                warn("\(prefix)\(glucose(value)) is outside Loop's recommended \(glucoseRange(bounds.recommended)).")
            }
        }

        switch setting {
        case .carbRatio, .basalRate, .insulinSensitivity:
            let kind: TherapySettingKind = setting == .carbRatio ? .carbRatio : setting == .basalRate ? .basalRate : .insulinSensitivity
            let entries = TherapySchedule.sorted(self.entries(for: kind))
            do {
                try TherapySchedule.validate(entries, kind: kind, glucoseUnit: glucoseUnit)
            } catch {
                block(error.localizedDescription)
                return issues
            }
            let unit = kind.unitLabel(glucoseUnit: glucoseUnit)
            let digits = kind.fractionDigits(glucoseUnit: glucoseUnit)
            let recommended = kind.recommendedRange(glucoseUnit: glucoseUnit)
            for entry in entries {
                let time = TherapySchedule.timeString(entry.start)
                let value = TherapySchedule.format(entry.value, digits: digits) + " " + unit
                if kind == .basalRate, let maximumBasalRate, entry.value > maximumBasalRate + 1e-9 {
                    block("\(time): \(value) is above the Maximum Basal Rate (\(insulin(maximumBasalRate, "U/h"))).")
                } else if !recommended.contains(entry.value) {
                    warn("\(time): \(value) is outside Loop's recommended " + TherapySchedule.formatRange(recommended.lowerBound, recommended.upperBound, digits: digits) + " \(unit).")
                }
            }

        case .correctionRange:
            do {
                try TherapySchedule.validateShape(correctionRanges)
            } catch {
                block(error.localizedDescription)
                return issues
            }
            let bounds = bounds(for: .correctionRange)!
            let raisedBySafetyLimit = suspendThreshold.map { $0 > TherapyGuardrails.convert(TherapyGuardrails.correctionRangeAbsolute.lowerBound, to: glucoseUnit) } ?? false
            for entry in TherapySchedule.sorted(correctionRanges) {
                let time = TherapySchedule.timeString(entry.start)
                if entry.low > entry.high {
                    block("\(time): the low value is above the high value.")
                    continue
                }
                checkGlucose(entry.low, label: time, bounds: bounds, lowerReason: raisedBySafetyLimit ? "the Glucose Safety Limit" : nil)
                checkGlucose(entry.high, label: time, bounds: bounds, lowerReason: raisedBySafetyLimit ? "the Glucose Safety Limit" : nil)
            }

        case .glucoseSafetyLimit:
            guard let suspendThreshold else { return issues }
            let bounds = bounds(for: .glucoseSafetyLimit)!
            let absoluteUpper = TherapySchedule.roundedInward(TherapyGuardrails.convert(TherapyGuardrails.suspendThresholdAbsolute, to: glucoseUnit), digits: g).upperBound
            checkGlucose(suspendThreshold, label: "", bounds: bounds,
                         upperReason: bounds.absolute.upperBound < absoluteUpper ? "the lowest Correction Range, Pre-Meal or Workout value" : nil)
            if workoutRange == nil, let previous = original.suspendThreshold, suspendThreshold > previous {
                warn("Nightscout doesn't show Loop's Workout Range. Loop rejects the change if the new limit is above the workout low.")
            }

        case .preMealRange, .workoutRange:
            guard let range = setting == .preMealRange ? preMealRange : workoutRange else { return issues }
            let bounds = bounds(for: setting)!
            let reason = suspendThreshold != nil ? "the Glucose Safety Limit" : nil
            checkGlucose(range.lowerBound, label: "Low", bounds: bounds, lowerReason: reason)
            checkGlucose(range.upperBound, label: "High", bounds: bounds, lowerReason: reason)

        case .maximumBasalRate:
            guard let maximumBasalRate else { return issues }
            let bounds = bounds(for: .maximumBasalRate)!
            if !TherapyGuardrails.isMultiple(maximumBasalRate, of: TherapyGuardrails.pumpIncrement) {
                block("\(insulin(maximumBasalRate, "U/h")) is not a step of 0.05 U/h the pump can deliver.")
            } else if maximumBasalRate < bounds.absolute.lowerBound - 1e-9 {
                block("\(insulin(maximumBasalRate, "U/h")) is below the highest basal rate (\(insulin(bounds.absolute.lowerBound, "U/h"))).")
            } else if maximumBasalRate > bounds.absolute.upperBound + 1e-9 {
                block("\(insulin(maximumBasalRate, "U/h")) is above what Loop allows with these basal rates and carb ratios (\(insulin(bounds.absolute.upperBound, "U/h"))).")
            } else if !bounds.recommended.contains(maximumBasalRate) {
                warn("\(insulin(maximumBasalRate, "U/h")) is outside Loop's recommended \(insulinRange(bounds.recommended, "U/h")).")
            }

        case .maximumBolus:
            guard let maximumBolus else { return issues }
            let bounds = TherapyGuardrails.maximumBolus
            if !TherapyGuardrails.isMultiple(maximumBolus, of: TherapyGuardrails.pumpIncrement) {
                block("\(insulin(maximumBolus, "U")) is not a step of 0.05 U the pump can deliver.")
            } else if !bounds.absolute.contains(maximumBolus) {
                block("\(insulin(maximumBolus, "U")) is outside what Loop allows (\(insulinRange(bounds.absolute, "U"))).")
            } else if !bounds.recommended.contains(maximumBolus) {
                warn("\(insulin(maximumBolus, "U")) is outside Loop's recommended \(insulinRange(bounds.recommended, "U")).")
            }

        case .insulinModel:
            if let insulinModel, InsulinModelOption(rawValue: insulinModel) == nil {
                block("\(insulinModel) is not an insulin model Loop knows.")
            }

        case .dosingStrategy:
            if let dosingStrategy, DosingStrategyOption(rawValue: dosingStrategy) == nil {
                block("\(dosingStrategy) is not a dosing strategy Loop knows.")
            }

        case .overridePresets:
            var names = Set<String>()
            for preset in overridePresets ?? [] {
                let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.isEmpty ? "A preset" : "\(preset.symbol) \(name)"
                if name.isEmpty {
                    block("Every preset needs a name.")
                } else if !names.insert(name).inserted {
                    block("\(name) is used by more than one preset.")
                }
                if preset.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    block("\(label) needs a symbol.")
                }
                if !TherapyGuardrails.insulinNeedsScaleFactors.contains(preset.insulinNeedsScaleFactor) {
                    block("\(label): overall insulin needs must be 10–200%.")
                }
                if preset.duration < 0 || preset.duration > TherapyGuardrails.maximumOverrideDuration {
                    block("\(label): the duration must be indefinite or at most 24 hours.")
                }
                if let target = preset.targetRange {
                    let limits = TherapyGuardrails.overrideTargetLimits(unit: glucoseUnit)
                    if !limits.contains(target.lowerBound) || !limits.contains(target.upperBound) {
                        block("\(label): the target \(glucoseRange(target)) is outside what Loop allows (\(glucoseRange(limits))).")
                    } else if let suspendThreshold, target.lowerBound < suspendThreshold {
                        warn("\(label): the target low \(glucose(target.lowerBound)) is below the Glucose Safety Limit (\(glucose(suspendThreshold))).")
                    } else {
                        let usual = TherapyGuardrails.convert(TherapyGuardrails.correctionRangeAbsolute, to: glucoseUnit)
                        if !usual.contains(target.lowerBound) || !usual.contains(target.upperBound) {
                            warn("\(label): the target \(glucoseRange(target)) is outside the range Loop allows for the Correction Range.")
                        }
                    }
                } else if preset.insulinNeedsPercent == 100 {
                    // Loop's own editor can't save a preset that changes nothing.
                    block("\(label) changes nothing: set a target or overall insulin needs other than 100%.")
                }
            }

        case .closedLoop, .glucoseBasedPartialApplication, .integralRetrospectiveCorrection:
            break
        }
        return issues
    }
}

extension TherapyGuardrails {
    /// The widest range a value can ever take, whatever the other settings are. An editor won't save a
    /// value outside; a value inside that the other settings rule out is shown as a problem to fix
    /// before sending, so settings that depend on each other can be changed in either order.
    static func limits(for setting: TherapySetting, unit: HKUnit) -> ClosedRange<Double>? {
        let digits = glucoseDigits(unit)
        switch setting {
        case .glucoseSafetyLimit:
            return TherapySchedule.roundedInward(convert(suspendThresholdAbsolute, to: unit), digits: digits)
        case .correctionRange:
            return TherapySchedule.roundedInward(convert(correctionRangeAbsolute, to: unit), digits: digits)
        case .preMealRange:
            return TherapySchedule.roundedInward(convert(suspendThresholdAbsolute.lowerBound ... preMealMaximum, to: unit), digits: digits)
        case .workoutRange:
            return TherapySchedule.roundedInward(convert(correctionRangeAbsolute.lowerBound ... workoutMaximum, to: unit), digits: digits)
        case .maximumBasalRate:
            return pumpIncrement ... supportedBasalRates.upperBound
        case .maximumBolus:
            return supportedBolusVolumes
        case .carbRatio:
            return TherapySchedule.allowedRangeRounded(kind: .carbRatio, glucoseUnit: unit)
        case .basalRate:
            return TherapySchedule.allowedRangeRounded(kind: .basalRate, glucoseUnit: unit)
        case .insulinSensitivity:
            return TherapySchedule.allowedRangeRounded(kind: .insulinSensitivity, glucoseUnit: unit)
        default:
            return nil
        }
    }
}
