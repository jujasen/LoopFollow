// LoopFollow
// ProfileManager.swift

import Foundation
import HealthKit

final class ProfileManager {
    // MARK: - Singleton Instance

    static let shared = ProfileManager()

    // MARK: - Properties

    var isfSchedule: [TimeValue<HKQuantity>]
    var basalSchedule: [TimeValue<Double>]
    var carbRatioSchedule: [TimeValue<Double>]
    var targetLowSchedule: [TimeValue<HKQuantity>]
    var targetHighSchedule: [TimeValue<HKQuantity>]
    var loopOverrides: [LoopOverride]
    var trioOverrides: [TrioOverride]
    var units: HKUnit
    var timezone: TimeZone
    var defaultProfile: String
    /// When the schedules above were last read from Nightscout.
    var loadedAt: Date?
    /// Loop's other therapy settings from the profile's `loopSettings`; nil where Loop did not upload one.
    var loopTherapySettings: LoopTherapySettings

    // MARK: - Nested Structures

    struct TimeValue<T> {
        let timeAsSeconds: Int
        let value: T
    }

    struct LoopOverride {
        let name: String
        let targetRange: [HKQuantity]
        let duration: Int?
        let insulinNeedsScaleFactor: Double
        let symbol: String
    }

    /// Glucose values are in `units`. Every value is optional: Loop only uploads some of them, and an
    /// older Loop none.
    struct LoopTherapySettings: Equatable {
        var suspendThreshold: Double?
        var preMealTargetRange: ClosedRange<Double>?
        var workoutTargetRange: ClosedRange<Double>?
        var maximumBasalRatePerHour: Double?
        var maximumBolus: Double?
        var dosingEnabled: Bool?
        var dosingStrategy: String?
        var insulinModel: String?
        var glucoseBasedApplicationFactorEnabled: Bool?
        var integralRetrospectiveCorrectionEnabled: Bool?
        /// False when the profile had no `loopSettings` at all, so the override presets are unknown
        /// rather than an empty list.
        var hasOverridePresets: Bool

        static let unknown = LoopTherapySettings(hasOverridePresets: false)

        init(suspendThreshold: Double? = nil, preMealTargetRange: ClosedRange<Double>? = nil, workoutTargetRange: ClosedRange<Double>? = nil,
             maximumBasalRatePerHour: Double? = nil, maximumBolus: Double? = nil, dosingEnabled: Bool? = nil, dosingStrategy: String? = nil,
             insulinModel: String? = nil, glucoseBasedApplicationFactorEnabled: Bool? = nil, integralRetrospectiveCorrectionEnabled: Bool? = nil,
             hasOverridePresets: Bool)
        {
            self.suspendThreshold = suspendThreshold
            self.preMealTargetRange = preMealTargetRange
            self.workoutTargetRange = workoutTargetRange
            self.maximumBasalRatePerHour = maximumBasalRatePerHour
            self.maximumBolus = maximumBolus
            self.dosingEnabled = dosingEnabled
            self.dosingStrategy = dosingStrategy
            self.insulinModel = insulinModel
            self.glucoseBasedApplicationFactorEnabled = glucoseBasedApplicationFactorEnabled
            self.integralRetrospectiveCorrectionEnabled = integralRetrospectiveCorrectionEnabled
            self.hasOverridePresets = hasOverridePresets
        }

        init(_ settings: NSProfile.LoopSettings?) {
            func range(_ values: [Double]?) -> ClosedRange<Double>? {
                guard let values, values.count == 2, values[0] <= values[1] else { return nil }
                return values[0] ... values[1]
            }
            self.init(
                suspendThreshold: settings?.minimumBGGuard,
                preMealTargetRange: range(settings?.preMealTargetRange),
                workoutTargetRange: range(settings?.workoutTargetRange),
                maximumBasalRatePerHour: settings?.maximumBasalRatePerHour,
                maximumBolus: settings?.maximumBolus,
                dosingEnabled: settings?.dosingEnabled,
                dosingStrategy: settings?.dosingStrategy,
                insulinModel: settings?.insulinModel,
                glucoseBasedApplicationFactorEnabled: settings?.glucoseBasedApplicationFactorEnabled,
                integralRetrospectiveCorrectionEnabled: settings?.integralRetrospectiveCorrectionEnabled,
                hasOverridePresets: settings?.overridePresets != nil
            )
        }
    }

    struct TrioOverride {
        let name: String
        let duration: Double?
        let percentage: Double?
        let target: HKQuantity?
    }

    // MARK: - Initializer

    private init() {
        isfSchedule = []
        basalSchedule = []
        carbRatioSchedule = []
        targetLowSchedule = []
        targetHighSchedule = []
        loopOverrides = []
        trioOverrides = []
        units = .millimolesPerLiter
        timezone = TimeZone.current
        defaultProfile = ""
        loopTherapySettings = .unknown
    }

    // MARK: - Methods

    func loadProfile(from profileData: NSProfile) {
        guard let store = profileData.store[profileData.defaultProfile] else {
            return
        }

        units = store.units.lowercased() == "mg/dl" ? .milligramsPerDeciliter : .millimolesPerLiter
        defaultProfile = profileData.defaultProfile
        loadedAt = Date()

        timezone = getTimeZone(from: store.timezone)

        isfSchedule = store.sens.map { TimeValue(timeAsSeconds: Int($0.timeAsSeconds), value: HKQuantity(unit: self.units, doubleValue: $0.value)) }
        basalSchedule = store.basal.map { TimeValue(timeAsSeconds: Int($0.timeAsSeconds), value: $0.value) }
        carbRatioSchedule = store.carbratio.map { TimeValue(timeAsSeconds: Int($0.timeAsSeconds), value: $0.value) }
        targetLowSchedule = store.target_low?.map { TimeValue(timeAsSeconds: Int($0.timeAsSeconds), value: HKQuantity(unit: self.units, doubleValue: $0.value)) } ?? []
        targetHighSchedule = store.target_high?.map { TimeValue(timeAsSeconds: Int($0.timeAsSeconds), value: HKQuantity(unit: self.units, doubleValue: $0.value)) } ?? []

        if let loopSettings = profileData.loopSettings,
           let overridePresets = loopSettings.overridePresets
        {
            loopOverrides = overridePresets.map { preset in
                let targetRangeQuantities = preset.targetRange?.map { HKQuantity(unit: self.units, doubleValue: $0) }
                return LoopOverride(
                    name: preset.name,
                    targetRange: targetRangeQuantities ?? [],
                    duration: preset.duration,
                    insulinNeedsScaleFactor: preset.insulinNeedsScaleFactor ?? 1.0,
                    symbol: preset.symbol ?? ""
                )
            }
        } else {
            loopOverrides = []
        }

        loopTherapySettings = LoopTherapySettings(profileData.loopSettings)

        if let trioOverrides = profileData.trioOverrides {
            self.trioOverrides = trioOverrides.map { entry in
                let targetQuantity = entry.target != nil ? HKQuantity(unit: .milligramsPerDeciliter, doubleValue: entry.target!) : nil
                return TrioOverride(
                    name: entry.name,
                    duration: entry.duration,
                    percentage: entry.percentage,
                    target: targetQuantity
                )
            }
        } else {
            trioOverrides = []
        }

        Storage.shared.deviceToken.value = profileData.deviceToken ?? profileData.loopSettings?.deviceToken ?? ""

        if let expirationDate = profileData.expirationDate {
            Storage.shared.expirationDate.value = NightscoutUtils.parseDate(expirationDate)
        } else {
            Storage.shared.expirationDate.value = nil
        }
        Storage.shared.bundleId.value = profileData.bundleIdentifier ?? profileData.loopSettings?.bundleIdentifier ?? ""

        if let isProduction = profileData.isAPNSProduction {
            Storage.shared.productionEnvironment.value = isProduction
        }

        Storage.shared.teamId.value = profileData.teamID ?? Storage.shared.teamId.value ?? ""
    }

    func currentISF() -> HKQuantity? {
        return getCurrentValue(from: isfSchedule)
    }

    func currentBasal() -> String? {
        if let basal = getCurrentValue(from: basalSchedule) {
            return Localizer.formatToLocalizedString(basal, maxFractionDigits: 2, minFractionDigits: 0)
        }
        return nil
    }

    func currentCarbRatio() -> Double? {
        return getCurrentValue(from: carbRatioSchedule)
    }

    func currentTargetLow() -> HKQuantity? {
        return getCurrentValue(from: targetLowSchedule)
    }

    func currentTargetHigh() -> HKQuantity? {
        return getCurrentValue(from: targetHighSchedule)
    }

    private func getCurrentValue<T>(from schedule: [TimeValue<T>]) -> T? {
        guard !schedule.isEmpty else { return nil }

        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = timezone

        let currentTimeInSeconds = calendar.component(.hour, from: now) * 3600 +
            calendar.component(.minute, from: now) * 60 +
            calendar.component(.second, from: now)

        var lastValue: T?
        for timeValue in schedule {
            if currentTimeInSeconds >= timeValue.timeAsSeconds {
                lastValue = timeValue.value
            } else {
                break
            }
        }
        return lastValue
    }

    private func getTimeZone(from identifier: String) -> TimeZone {
        if let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }

        let adjustedIdentifier = identifier.replacingOccurrences(of: "ETC/", with: "Etc/")
        if let timeZone = TimeZone(identifier: adjustedIdentifier) {
            return timeZone
        }

        if identifier.uppercased().contains("GMT") {
            let components = identifier.uppercased().components(separatedBy: "GMT")
            if components.count > 1 {
                let offsetString = components[1]
                if let offsetHours = Int(offsetString) {
                    let correctedOffsetHours = -offsetHours
                    let secondsFromGMT = correctedOffsetHours * 3600
                    if let timeZone = TimeZone(secondsFromGMT: secondsFromGMT) {
                        return timeZone
                    }
                }
            }
        }

        return TimeZone.current
    }

    func clear() {
        isfSchedule = []
        basalSchedule = []
        carbRatioSchedule = []
        targetLowSchedule = []
        targetHighSchedule = []
        loopOverrides = []
        trioOverrides = []
        units = .millimolesPerLiter
        timezone = TimeZone.current
        defaultProfile = ""
        loadedAt = nil
        loopTherapySettings = .unknown
    }
}
