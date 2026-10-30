// LoopFollow
// EveningWatchCondition.swift

import Foundation

/// The evening watch as an alarm: sounds while it has a suggestion open (see `EveningWatch`).
///
/// • `aboveBG` – glucose at or above this
/// • `persistentMinutes` – every reading over this long must be near it
/// • `threshold` – no suggestion with this much insulin on board
/// • `eveningStartMinutes`, `eveningEndMinutes` – the window, minutes after midnight
/// • `eveningStartUnits` – the dose before anything is learned
struct EveningWatchCondition: AlarmCondition {
    static let type: AlarmType = .eveningWatch

    private let loadState: () -> EveningWatch.State
    private let saveState: (EveningWatch.State) -> Void

    init() {
        loadState = { Storage.shared.eveningWatchState.value }
        saveState = { Storage.shared.eveningWatchState.value = $0 }
    }

    /// For tests: keeps the state somewhere other than `Storage`.
    init(load: @escaping () -> EveningWatch.State, save: @escaping (EveningWatch.State) -> Void) {
        loadState = load
        saveState = save
    }

    var checksOwnBGLimits: Bool { true }

    func evaluate(alarm: Alarm, data: AlarmData, now: Date) -> Bool {
        guard let input = data.eveningWatch else { return false }
        let stored = loadState()
        let result = EveningWatch.tick(stored, input: input, settings: EveningWatch.Settings(alarm: alarm), now: now)
        if result.state != stored {
            saveState(result.state)
        }
        return result.fire
    }
}

extension EveningWatch.Settings {
    init(alarm: Alarm) {
        self.init()
        if let value = alarm.eveningStartMinutes { start = value }
        if let value = alarm.eveningEndMinutes { end = value }
        if let value = alarm.aboveBG { glucose = value }
        if let value = alarm.persistentMinutes { persistent = TimeInterval(value * 60) }
        if let value = alarm.threshold { maximumIOB = value }
        if let value = alarm.eveningStartUnits { startUnits = value }
    }

    /// The settings of the evening watch in the alarm list, or the defaults.
    static var current: EveningWatch.Settings {
        Storage.shared.alarms.value.first { $0.type == .eveningWatch }.map(EveningWatch.Settings.init(alarm:)) ?? .init()
    }
}
