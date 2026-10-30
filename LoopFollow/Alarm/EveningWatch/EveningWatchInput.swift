// LoopFollow
// EveningWatchInput.swift

import Foundation

extension MainViewController {
    /// What `EveningWatchCondition` needs: four and a half hours of glucose (the three after a
    /// given suggestion are what it learns from), six of boluses and carbs.
    func eveningWatchInput(now: Date = Date()) -> EveningWatch.Input {
        let glucoseSince = now.addingTimeInterval(-4.5 * 3600).timeIntervalSince1970
        let since = now.addingTimeInterval(-6 * 3600).timeIntervalSince1970
        let glucose = bgData
            .filter { $0.date >= glucoseSince && $0.sgv > 0 }
            .map { GlucoseValue(sgv: $0.sgv, date: Date(timeIntervalSince1970: $0.date)) }
        // `bolusData` holds the boluses not marked automatic: given in Loop by hand or sent from here.
        let boluses = bolusData
            .filter { $0.date >= since }
            .map { BolusEntry(units: $0.value, date: Date(timeIntervalSince1970: $0.date)) }
            .sorted { $0.date < $1.date }
        let carbs = carbData
            .filter { $0.date >= since }
            .map { CarbSample(grams: $0.value, date: Date(timeIntervalSince1970: $0.date)) }
            .sorted { $0.date < $1.date }
        return EveningWatch.Input(
            glucose: glucose,
            manualBoluses: boluses,
            carbs: carbs,
            iob: latestIOB?.value,
            maximumBolus: ProfileManager.shared.loopTherapySettings.maximumBolus
        )
    }
}
