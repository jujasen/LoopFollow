// LoopFollow
// PumpDeliveryInput.swift

import Foundation
import HealthKit

extension ProfileManager {
    static func insulinCurve(_ settings: NSProfile.LoopSettings?) -> PumpDeliveryCheck.InsulinCurve {
        var curve = PumpDeliveryCheck.InsulinCurve(model: settings?.insulin?.effectiveModel ?? settings?.insulinModel)
        if let peak = settings?.insulin?.peakMinutes, peak > 0 { curve.peak = peak * 60 }
        if let hours = settings?.insulin?.durationHours, hours > 0 { curve.duration = hours * 3600 }
        if let delay = settings?.insulin?.delayMinutes, delay >= 0 { curve.delay = delay * 60 }
        return curve
    }

    /// ISF as mg/dL per unit.
    var pumpCheckSensitivity: PumpDeliveryCheck.Schedule? {
        guard !isfSchedule.isEmpty else { return nil }
        return PumpDeliveryCheck.Schedule(
            items: isfSchedule.map { .init(secondsFromMidnight: $0.timeAsSeconds, value: $0.value.doubleValue(for: .milligramsPerDeciliter)) },
            timeZone: timezone
        )
    }

    var pumpCheckCarbRatio: PumpDeliveryCheck.Schedule? {
        guard !carbRatioSchedule.isEmpty else { return nil }
        return PumpDeliveryCheck.Schedule(items: carbRatioSchedule.map { .init(secondsFromMidnight: $0.timeAsSeconds, value: $0.value) }, timeZone: timezone)
    }

    var pumpCheckBasal: PumpDeliveryCheck.Schedule? {
        guard !basalSchedule.isEmpty else { return nil }
        return PumpDeliveryCheck.Schedule(items: basalSchedule.map { .init(secondsFromMidnight: $0.timeAsSeconds, value: $0.value) }, timeZone: timezone)
    }
}

extension PumpDeliveryCheck {
    /// Net basal against the schedule, from the step series LoopFollow draws: a
    /// segment is two consecutive points at the same rate, later than each other.
    static func netBasal(rates: [(rate: Double, date: Date)], scheduled: Schedule, from start: Date, to now: Date) -> [Dose] {
        zip(rates, rates.dropFirst()).compactMap { from, to -> [Dose]? in
            guard from.rate == to.rate else { return nil }
            let begin = max(from.date, start)
            let end = min(to.date, now)
            guard end > begin else { return nil }
            var doses: [Dose] = []
            var at = begin
            // Split where the schedule may change.
            while at < end {
                let next = min(end, at.addingTimeInterval(300))
                let planned = scheduled.value(at: at) ?? 0
                doses.append(Dose(start: at, end: next, units: (from.rate - planned) * next.timeIntervalSince(at) / 3600))
                at = next
            }
            return doses
        }.flatMap { $0 }
    }
}

extension MainViewController {
    /// What `PumpFailureCondition` needs: four hours of glucose, seven of insulin, eight of carbs.
    func pumpDeliveryCheck(now: Date = Date()) -> PumpDeliveryCheck? {
        let profile = ProfileManager.shared
        guard let isf = profile.pumpCheckSensitivity,
              let ratio = profile.pumpCheckCarbRatio,
              let basal = profile.pumpCheckBasal
        else { return nil }

        let glucoseSince = now.addingTimeInterval(-4 * 3600).timeIntervalSince1970
        let insulinSince = now.addingTimeInterval(-7 * 3600)
        let carbSince = now.addingTimeInterval(-8 * 3600).timeIntervalSince1970

        let glucose = bgData
            .filter { $0.date >= glucoseSince && $0.sgv > 0 }
            .map { GlucoseValue(sgv: $0.sgv, date: Date(timeIntervalSince1970: $0.date)) }
        let boluses = (bolusData + smbData)
            .filter { $0.date >= insulinSince.timeIntervalSince1970 && $0.date <= now.timeIntervalSince1970 }
            .map { PumpDeliveryCheck.Dose(start: Date(timeIntervalSince1970: $0.date), end: Date(timeIntervalSince1970: $0.date), units: $0.value) }
        let basals = PumpDeliveryCheck.netBasal(
            rates: basalData.map { (rate: $0.basalRate, date: Date(timeIntervalSince1970: $0.date)) },
            scheduled: basal,
            from: insulinSince,
            to: now
        )
        let carbs = carbData
            .filter { $0.date >= carbSince && $0.date <= now.timeIntervalSince1970 }
            .map { PumpDeliveryCheck.Carb(date: Date(timeIntervalSince1970: $0.date), grams: $0.value, absorption: TimeInterval(($0.absorptionTime > 0 ? $0.absorptionTime : 180) * 60)) }

        return PumpDeliveryCheck(
            glucose: glucose,
            doses: (boluses + basals).sorted { $0.start < $1.start },
            carbs: carbs,
            sensitivity: isf,
            carbRatio: ratio,
            curve: profile.insulinCurve
        )
    }
}
