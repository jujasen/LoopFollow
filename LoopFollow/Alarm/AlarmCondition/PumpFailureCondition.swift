// LoopFollow
// PumpFailureCondition.swift

import Foundation

/// Fires when glucose stays high and is not falling although the insulin given
/// should have brought it well down — the pump may not be delivering (see
/// `PumpDeliveryCheck`).
///
/// • `aboveBG` – glucose at or above this
/// • `delta` – rise not explained by insulin and carbs over 90 min, at or above this
/// • `threshold` – drop the insulin should have caused over 90 min, at or above this
/// • `persistentMinutes` – every reading over this long must meet the above
///
/// Once acknowledged («Jeg har sjekket») it stays silent until the latest reading no
/// longer meets the limits or the pod is changed; see `PumpFailureAcknowledgement`.
struct PumpFailureCondition: AlarmCondition {
    static let type: AlarmType = .pumpFailure

    private let loadAcknowledgement: () -> PumpFailureAcknowledgement?
    private let saveAcknowledgement: (PumpFailureAcknowledgement?) -> Void

    init() {
        loadAcknowledgement = { Storage.shared.pumpFailureAcknowledgement.value }
        saveAcknowledgement = { Storage.shared.pumpFailureAcknowledgement.value = $0 }
    }

    /// For tests: keeps the acknowledgement somewhere other than `Storage`.
    init(load: @escaping () -> PumpFailureAcknowledgement?, save: @escaping (PumpFailureAcknowledgement?) -> Void) {
        loadAcknowledgement = load
        saveAcknowledgement = save
    }

    var checksOwnBGLimits: Bool { true }

    static func limits(for alarm: Alarm) -> PumpDeliveryCheck.Limits {
        var limits = PumpDeliveryCheck.Limits()
        if let value = alarm.aboveBG { limits.glucose = value }
        if let value = alarm.delta { limits.unexplainedRise = value }
        if let value = alarm.threshold { limits.insulinDrop = value }
        if let value = alarm.persistentMinutes { limits.persistent = TimeInterval(value * 60) }
        return limits
    }

    /// Whether the latest reading meets the limits; nil when there is no recent
    /// reading or it cannot be assessed.
    static func latestMeetsLimits(_ check: PumpDeliveryCheck, limits: PumpDeliveryCheck.Limits, now: Date) -> Bool? {
        guard let latest = check.glucose.last,
              now.timeIntervalSince(latest.date) <= 10 * 60,
              let assessment = check.assess(at: latest)
        else { return nil }
        return check.meets(assessment, limits)
    }

    func evaluate(alarm: Alarm, data: AlarmData, now: Date) -> Bool {
        guard let check = data.pumpDelivery else { return false }
        let limits = Self.limits(for: alarm)

        let assessment = check.suspectedFailure(now: now, limits: limits)
        if let assessment {
            Observable.shared.pumpFailureAssessment.value = assessment
        }

        let stored = loadAcknowledgement()
        let outcome = PumpFailureAcknowledgement.resolve(
            stored,
            suspected: assessment != nil,
            latestMeetsLimits: stored == nil ? nil : Self.latestMeetsLimits(check, limits: limits, now: now),
            podInsertTime: data.pumpInsertTime
        )
        if outcome.acknowledgement != stored {
            saveAcknowledgement(outcome.acknowledgement)
        }
        return outcome.fire
    }
}
