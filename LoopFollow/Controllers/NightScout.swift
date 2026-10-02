// LoopFollow
// NightScout.swift

import Foundation

extension MainViewController {
    // NS Cage Struct
    struct cageData: Codable {
        var created_at: String
    }

    struct sageData: Codable {
        var created_at: String
    }

    struct iageData: Codable {
        var created_at: String
    }

    // NS Basal Profile Struct
    struct basalProfileStruct: Codable {
        var value: Double
        var time: String
        var timeAsSeconds: Double
    }

    // NS Basal Data  Struct
    struct basalGraphStruct: Codable {
        var basalRate: Double
        var date: TimeInterval
    }

    // NS Bolus Data  Struct
    struct bolusGraphStruct: Codable {
        var value: Double
        var date: TimeInterval
        var sgv: Int
    }

    // NS Bolus Data  Struct
    struct carbGraphStruct: Codable {
        var value: Double
        var date: TimeInterval
        var sgv: Int
        var absorptionTime: Int
        /// Loop's emoji, plus the dish's name when one was given (see `CarbFoodLabel`).
        var foodType: String? = nil
    }

    // A waiting "later carbs" plan, at the carb lane's height
    struct plannedCarbGraphStruct {
        var plan: PlannedCarb
        var sgv: Int
    }

    func clearOldTempBasal() {
        basalData.removeAll()
        updateBasalGraph()
    }

    func clearOldBolus() {
        bolusData.removeAll()
        updateBolusGraph()
    }

    func clearOldSmb() {
        smbData.removeAll()
        updateSmbGraph()
    }

    func clearOldCarb() {
        carbData.removeAll()
        updateCarbGraph()
    }

    func clearOldPlannedCarbs() {
        plannedCarbData.removeAll()
        updateCarbGraph()
    }

    func clearOldBGCheck() {
        bgCheckData.removeAll()
        updateBGCheckGraph()
    }

    func clearOldOverride() {
        overrideGraphData.removeAll()
        Observable.shared.override.value = nil
        Observable.shared.overrideEndAt.value = nil
        updateOverrideGraph()
    }

    func clearOldTempTarget() {
        tempTargetGraphData.removeAll()
        Observable.shared.tempTarget.value = nil
        Observable.shared.tempTargetEndAt.value = nil
        updateTempTargetGraph()
    }

    func clearOldSuspend() {
        suspendGraphData.removeAll()
        updateSuspendGraph()
    }

    func clearOldResume() {
        resumeGraphData.removeAll()
        updateResumeGraph()
    }

    func clearOldSensor() {
        sensorStartGraphData.removeAll()
        updateSensorStart()
    }

    func clearOldNotes() {
        noteGraphData.removeAll()
        updateNotes()
    }
}
