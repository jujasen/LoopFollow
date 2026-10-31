// LoopFollow
// EveningWatchCondition.swift

import Foundation

/// Loop's evening watch as an alarm: sounds while one of its suggestions is open and not
/// declined here (see `EveningWatch`). Loop decides; this only announces.
struct EveningWatchCondition: AlarmCondition {
    static let type: AlarmType = .eveningWatch

    var checksOwnBGLimits: Bool { true }

    func evaluate(alarm _: Alarm, data: AlarmData, now _: Date) -> Bool {
        data.eveningWatch != nil
    }
}
