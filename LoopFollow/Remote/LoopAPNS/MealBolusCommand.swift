// LoopFollow
// MealBolusCommand.swift

import Foundation

/// «Save and deliver» from here: one signed command that makes Loop save the meal and bolus for it
/// at once, as Loop's own carb screen does.
///
/// Before, carbs went first, then the caregiver waited about five minutes for Loop to upload a
/// recommendation that counted them, and sent the bolus as a second command. Now Loop gets the carbs
/// and the most the caregiver approves, works the dose out again with the meal, saves the carbs and
/// gives the smaller of its own recommendation and the approved amount (when the caregiver kept the
/// suggested number), then answers in Nightscout.
///
/// The keys are new on purpose (not `carbs-entry`/`bolus-entry`): a Loop without the command rejects
/// it as unknown instead of carrying out half of it. The contract is shared with the jujasen fork of
/// Loop (NightscoutService `RemoteCommandInbox`); don't rename the keys.
enum MealBolusCommand {
    /// What Loop puts in `testingDetails.remoteCommands` when it takes the command.
    static let capability = "mealBolus"
    /// `statusDetails.kind` in Loop's answer.
    static let detailsKind = "mealBolus"

    enum Key {
        static let carbs = "meal-carbs"
        static let absorptionTime = "meal-absorption-time"
        static let foodType = "meal-food-type"
        static let startTime = "meal-start-time"
        static let bolus = "meal-bolus"
        static let followsRecommendation = "meal-bolus-follows-recommendation"
    }

    /// Offered only when this Loop says it takes the command and commands go through the Nightscout
    /// inbox (the command needs Loop's answer there; a bare push could be half lost).
    static func isOffered(remoteCommands: [String], inboxAvailable: Bool) -> Bool {
        inboxAvailable && remoteCommands.contains(capability)
    }

    static var isOffered: Bool {
        isOffered(remoteCommands: Storage.shared.loopRemoteCommands.value, inboxAvailable: RemoteCommandInbox.shared.isAvailable)
    }

    /// The command's own keys plus the ones every command carries. `RemoteCommandInbox.inboxPayload`
    /// adds the command id and replaces the times; there is no password, the signature stands for it.
    static func payload(_ request: MealBolusRequest, knownDosesUntil: Date, now: Date) -> [String: Any] {
        let units = MealBolusEstimate.rounded(request.bolus)
        var payload: [String: Any] = [
            Key.carbs: request.carbs,
            Key.absorptionTime: request.absorptionHours,
            Key.startTime: RemoteCommandInbox.format(request.startTime),
            Key.bolus: units,
            Key.followsRecommendation: request.followsRecommendation,
            DoseGuard.keyInPayload: RemoteCommandInbox.format(knownDosesUntil),
            "remote-address": "LoopFollow",
            "entered-by": "LoopFollow",
            "notes": "Sent via LoopFollow APNS",
            "sent-at": RemoteCommandInbox.format(now),
            "expiration": RemoteCommandInbox.format(now.addingTimeInterval(RemoteCommandInbox.lifetime)),
            "alert": "Remote Meal: \(String(format: "%.0f", request.carbs)) g + \(String(format: "%.2f", units)) U",
        ]
        if let foodType = request.foodType, !foodType.isEmpty {
            payload[Key.foodType] = foodType
        }
        return payload
    }
}

/// What the caregiver approved on the meal bolus screen.
struct MealBolusRequest: Equatable {
    var carbs: Double
    var absorptionHours: Double
    var foodType: String?
    var startTime: Date
    /// The most Loop may give.
    var bolus: Double
    /// The caregiver left LoopFollow's suggestion as it was: Loop then gives the smaller of it and its own.
    var followsRecommendation: Bool
}

/// What a meal bolus sent from here was, and what Loop said became of it (`statusDetails`).
struct MealBolusDetails: Codable, Equatable {
    let carbs: Double
    let approvedUnits: Double
    var foodType: String?
    var absorptionHours: Double?
    var startTime: Date?
    /// From Loop's answer: the carbs are in Loop, whatever became of the bolus.
    var carbsSaved: Bool?
    /// Loop's own recommendation with the meal, when it could work one out.
    var recommendedUnits: Double?
    /// What Loop asked the pump for; 0 when it gave no bolus.
    var deliveredUnits: Double?

    init(request: MealBolusRequest) {
        carbs = request.carbs
        approvedUnits = MealBolusEstimate.rounded(request.bolus)
        foodType = request.foodType
        absorptionHours = request.absorptionHours
        startTime = request.startTime
    }

    init(carbs: Double, approvedUnits: Double, carbsSaved: Bool? = nil, recommendedUnits: Double? = nil, deliveredUnits: Double? = nil) {
        self.carbs = carbs
        self.approvedUnits = approvedUnits
        self.carbsSaved = carbsSaved
        self.recommendedUnits = recommendedUnits
        self.deliveredUnits = deliveredUnits
    }

    /// Takes in Loop's `statusDetails` for this command.
    mutating func apply(statusDetails details: [String: Any]) {
        guard details["kind"] as? String == MealBolusCommand.detailsKind else { return }
        if let saved = details["carbsSaved"] as? Bool {
            carbsSaved = saved
        }
        if let units = (details["recommendedUnits"] as? NSNumber)?.doubleValue {
            recommendedUnits = units
        }
        if let units = (details["deliveredUnits"] as? NSNumber)?.doubleValue {
            deliveredUnits = units
        }
    }
}

/// LoopFollow's guess at the bolus for a meal, shown before sending.
///
/// LoopFollow can't run Loop's algorithm. It takes Loop's latest uploaded recommendation while that
/// is still good (no bolus since the cycle that made it, and less than 12 minutes old) and adds the
/// carbs divided by the current carb ratio, never below 0, rounded down to 0.05 U and no more than
/// the maximum bolus. Loop works the real dose out again with the meal when the command arrives, and
/// never gives more than the caregiver approved.
struct MealBolusEstimate: Equatable {
    static let step = 0.05
    /// Matches the bolus screen: an older recommendation is not offered.
    static let recommendationLifetime: TimeInterval = 12 * 60

    let units: Double
    /// Loop's recommendation that went into it (0 without one).
    let fromRecommendation: Double
    let recommendationAt: Date?
    /// carbs ÷ carb ratio, unrounded.
    let forCarbs: Double
    let carbRatio: Double
    /// The sum was more than the maximum bolus.
    let cappedAtMax: Bool

    static func make(carbs: Double, carbRatio: Double?, recommendation: (units: Double, at: Date)?, maxBolus: Double?, now: Date) -> MealBolusEstimate? {
        guard let carbRatio, carbRatio > 0, carbs >= 0 else { return nil }
        var fromRecommendation = 0.0
        var recommendationAt: Date?
        if let recommendation, now.timeIntervalSince(recommendation.at) < recommendationLifetime, now.timeIntervalSince(recommendation.at) > -5 * 60 {
            fromRecommendation = max(0, recommendation.units)
            recommendationAt = recommendation.at
        }
        let forCarbs = carbs / carbRatio
        var units = roundedDown(max(0, fromRecommendation + forCarbs))
        var capped = false
        if let maxBolus, maxBolus > 0, units > maxBolus {
            units = roundedDown(maxBolus)
            capped = true
        }
        return MealBolusEstimate(units: units, fromRecommendation: fromRecommendation, recommendationAt: recommendationAt, forCarbs: forCarbs, carbRatio: carbRatio, cappedAtMax: capped)
    }

    /// The estimate from what LoopFollow knows now.
    static func current(carbs: Double, now: Date = Date()) -> MealBolusEstimate? {
        let recommendation = RecommendedBolus.current().map { (units: $0.units, at: Date(timeIntervalSince1970: $0.at)) }
        return make(
            carbs: carbs,
            carbRatio: ProfileManager.shared.currentCarbRatio() ?? Storage.shared.lastCarbRatio.value,
            recommendation: recommendation,
            maxBolus: maxBolus,
            now: now
        )
    }

    /// The smaller of LoopFollow's own limit and Loop's, when Loop uploaded one.
    static var maxBolus: Double {
        let own = Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit())
        if let loops = ProfileManager.shared.loopTherapySettings.maximumBolus, loops > 0 {
            return min(own, loops)
        }
        return own
    }

    static func roundedDown(_ units: Double) -> Double {
        rounded((units / step + 1e-9).rounded(.down) * step)
    }

    /// Two decimals, so 3.2500000001 goes to Loop as 3.25.
    static func rounded(_ units: Double) -> Double {
        (units * 1000).rounded() / 1000
    }
}
