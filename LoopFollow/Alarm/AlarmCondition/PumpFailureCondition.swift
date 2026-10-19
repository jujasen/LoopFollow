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
struct PumpFailureCondition: AlarmCondition {
    static let type: AlarmType = .pumpFailure
    init() {}

    var checksOwnBGLimits: Bool { true }

    func evaluate(alarm: Alarm, data: AlarmData, now: Date) -> Bool {
        guard let check = data.pumpDelivery else { return false }
        var limits = PumpDeliveryCheck.Limits()
        if let value = alarm.aboveBG { limits.glucose = value }
        if let value = alarm.delta { limits.unexplainedRise = value }
        if let value = alarm.threshold { limits.insulinDrop = value }
        if let value = alarm.persistentMinutes { limits.persistent = TimeInterval(value * 60) }

        guard let assessment = check.suspectedFailure(now: now, limits: limits) else { return false }
        Observable.shared.pumpFailureAssessment.value = assessment
        return true
    }
}
