// LoopFollow
// MealBolusTests.swift

import Foundation
@testable import LoopFollow
import Testing

@Suite(.serialized)
struct MealBolusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(bolus: Double = 3.25, follows: Bool = true, foodType: String? = "🍕 Pizza") -> MealBolusRequest {
        MealBolusRequest(carbs: 45, absorptionHours: 4, foodType: foodType, startTime: now.addingTimeInterval(-120), bolus: bolus, followsRecommendation: follows)
    }

    // MARK: The command

    @Test("the payload carries the contract's keys, not carbs-entry or bolus-entry")
    func payloadKeys() {
        let known = now.addingTimeInterval(-600)
        let payload = MealBolusCommand.payload(request(), knownDosesUntil: known, now: now)
        #expect(Set(payload.keys) == [
            "meal-carbs", "meal-absorption-time", "meal-food-type", "meal-start-time", "meal-bolus",
            "meal-bolus-follows-recommendation", "known-doses-until",
            "remote-address", "entered-by", "notes", "sent-at", "expiration", "alert",
        ])
        #expect(payload["carbs-entry"] == nil)
        #expect(payload["bolus-entry"] == nil)
        #expect(payload["otp"] == nil)
        #expect(payload["meal-carbs"] as? Double == 45)
        #expect(payload["meal-absorption-time"] as? Double == 4)
        #expect(payload["meal-food-type"] as? String == "🍕 Pizza")
        #expect(payload["meal-bolus"] as? Double == 3.25)
        #expect(payload["meal-bolus-follows-recommendation"] as? Bool == true)
        #expect(payload["meal-start-time"] as? String == RemoteCommandInbox.format(now.addingTimeInterval(-120)))
        #expect(payload["known-doses-until"] as? String == RemoteCommandInbox.format(known))
        #expect(payload["entered-by"] as? String == "LoopFollow")
        #expect(payload["remote-address"] as? String == "LoopFollow")
    }

    @Test("an amount the user typed is sent as not following the recommendation")
    func followsRecommendationFlag() {
        let payload = MealBolusCommand.payload(request(bolus: 2, follows: false), knownDosesUntil: now, now: now)
        #expect(payload["meal-bolus-follows-recommendation"] as? Bool == false)
        #expect(payload["meal-bolus"] as? Double == 2)
    }

    @Test("no food type key without a food, and the bolus without float noise")
    func optionalFoodAndRounding() {
        let payload = MealBolusCommand.payload(request(bolus: 3.2500000001, foodType: nil), knownDosesUntil: now, now: now)
        #expect(payload["meal-food-type"] == nil)
        #expect(payload["meal-bolus"] as? Double == 3.25)
    }

    @Test("in Nightscout it gets a command id, no password, and a signature over exactly its payload")
    func signedTreatment() throws {
        let push = MealBolusCommand.payload(request(), knownDosesUntil: now, now: now)
        let inbox = RemoteCommandInbox.inboxPayload(from: push, commandId: "M1", sentAt: now)
        #expect(inbox["command-id"] as? String == "M1")
        #expect(inbox["otp"] == nil)
        #expect(inbox["meal-bolus"] as? Double == 3.25)
        let treatment = try RemoteCommandInbox.treatment(payload: inbox, commandId: "M1", summary: "Meal", secret: "S", sentAt: now)
        let json = try #require(treatment["payload"] as? String)
        #expect(treatment["signature"] as? String == RemoteCommandInbox.sign(payload: json, secret: "S"))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["meal-carbs"] as? Double == 45)
        #expect(decoded["meal-bolus-follows-recommendation"] as? Bool == true)
        #expect(decoded["command-id"] as? String == "M1")
    }

    @Test("offered only when Loop announces it and the inbox is in use")
    func capabilityGate() {
        #expect(MealBolusCommand.isOffered(remoteCommands: ["mealBolus"], inboxAvailable: true))
        #expect(!MealBolusCommand.isOffered(remoteCommands: ["mealBolus"], inboxAvailable: false))
        #expect(!MealBolusCommand.isOffered(remoteCommands: ["profileSwitch"], inboxAvailable: true))
        #expect(!MealBolusCommand.isOffered(remoteCommands: [], inboxAvailable: true))
    }

    // MARK: The estimate

    @Test("Loop's fresh recommendation plus carbs ÷ ratio, rounded down to 0.05 U")
    func estimateAddsRecommendation() throws {
        let estimate = try #require(MealBolusEstimate.make(carbs: 45, carbRatio: 15, recommendation: (1.17, now.addingTimeInterval(-120)), maxBolus: 10, now: now))
        #expect(abs(estimate.units - 4.15) < 1e-9)
        #expect(estimate.fromRecommendation == 1.17)
        #expect(abs(estimate.forCarbs - 3) < 1e-9)
        #expect(!estimate.cappedAtMax)
    }

    @Test("a recommendation 12 minutes old or more is left out")
    func estimateIgnoresStaleRecommendation() throws {
        let estimate = try #require(MealBolusEstimate.make(carbs: 45, carbRatio: 15, recommendation: (1.15, now.addingTimeInterval(-12 * 60)), maxBolus: 10, now: now))
        #expect(estimate.units == 3)
        #expect(estimate.recommendationAt == nil)
    }

    @Test("rounded down, never below 0, capped at the maximum bolus")
    func estimateLimits() throws {
        let small = try #require(MealBolusEstimate.make(carbs: 10, carbRatio: 12, recommendation: nil, maxBolus: 10, now: now))
        #expect(small.units == 0.8, "0.833 rounds down")
        let negative = try #require(MealBolusEstimate.make(carbs: 0, carbRatio: 12, recommendation: (-0.5, now), maxBolus: 10, now: now))
        #expect(negative.units == 0)
        let capped = try #require(MealBolusEstimate.make(carbs: 120, carbRatio: 10, recommendation: nil, maxBolus: 5, now: now))
        #expect(capped.units == 5)
        #expect(capped.cappedAtMax)
        let exact = try #require(MealBolusEstimate.make(carbs: 4.5, carbRatio: 15, recommendation: nil, maxBolus: nil, now: now))
        #expect(exact.units == 0.3, "0.3 is not rounded down to 0.25 by float noise")
    }

    @Test("no estimate without a carb ratio")
    func estimateNeedsCarbRatio() {
        #expect(MealBolusEstimate.make(carbs: 45, carbRatio: nil, recommendation: nil, maxBolus: 10, now: now) == nil)
        #expect(MealBolusEstimate.make(carbs: 45, carbRatio: 0, recommendation: nil, maxBolus: 10, now: now) == nil)
    }

    // MARK: Loop's answer

    private func mealCommand(_ status: QueuedRemoteCommand.Status = .pending) -> QueuedRemoteCommand {
        QueuedRemoteCommand(
            commandId: "M1",
            objectId: "ns1",
            summary: "Måltid 45 g + 3,25 E",
            units: 3.25,
            sentAt: now,
            expiration: now.addingTimeInterval(RemoteCommandInbox.lifetime),
            status: status,
            meal: MealBolusDetails(request: request())
        )
    }

    private func answer(_ status: String, _ details: [String: Any], message: String? = nil, handledAt: Date? = nil) -> [String: Any] {
        var treatment: [String: Any] = ["_id": "ns1", "commandId": "M1", "status": status, "statusDetails": details]
        if let message { treatment["statusMessage"] = message }
        treatment["handledAt"] = RemoteCommandInbox.format(handledAt ?? now.addingTimeInterval(40))
        return treatment
    }

    /// The sentence that says it is safe to send again (in whatever language the tests run in).
    private static func nothingSaved(_ message: String) -> String {
        String(format: String(localized: "Neither the carbs nor the bolus were saved. Loop said: %@ It is safe to send again.", table: "RemoteCommandInbox"), message)
    }

    @Test("done with a bolus: given, with what Loop gave and worked out")
    func doneWithBolus() {
        var command = mealCommand()
        command.apply(treatment: answer("done", ["kind": "mealBolus", "carbsSaved": true, "carbs": 45, "approvedUnits": 3.25, "recommendedUnits": 3.2, "deliveredUnits": 3.2]))
        #expect(command.phase(now: now.addingTimeInterval(60)) == .given)
        #expect(command.meal?.carbsSaved == true)
        #expect(command.meal?.recommendedUnits == 3.2)
        #expect(command.meal?.deliveredUnits == 3.2)
        #expect(command.receivedAt == now.addingTimeInterval(40))
        #expect(command.carbsSaved)
        #expect(!command.mayStillDeliver(now: now.addingTimeInterval(60)))
    }

    @Test("done without a bolus: the carbs are saved and nothing was given")
    func doneWithoutBolus() {
        var command = mealCommand()
        command.apply(treatment: answer("done", ["kind": "mealBolus", "carbsSaved": true, "carbs": 45, "approvedUnits": 3.25, "recommendedUnits": 0, "deliveredUnits": 0]))
        #expect(command.phase(now: now.addingTimeInterval(60)) == .savedWithoutBolus)
        #expect(RemoteCommandText.notification(command, now: now.addingTimeInterval(60)) != nil)
    }

    @Test("carbs saved, bolus failed: never offers to send the carbs again")
    func carbsSavedBolusFailed() {
        var command = mealCommand()
        command.apply(treatment: answer("failed", ["kind": "mealBolus", "carbsSaved": true, "carbs": 45, "approvedUnits": 3.25, "deliveredUnits": 0], message: "Pump not reachable."))
        let later = now.addingTimeInterval(60)
        #expect(command.phase(now: later) == .carbsSavedBolusFailed)
        #expect(command.carbsSaved)
        #expect(!command.mayStillDeliver(now: later))
        let detail = RemoteCommandText.detail(command, now: later)
        #expect(detail != Self.nothingSaved("Pump not reachable."))
        #expect(detail == String(format: String(localized: "Loop saved %@ g but did not give the bolus. Loop said: %@ Don't send the carbs again; give a bolus on its own if one is needed.", table: "RemoteCommandInbox"), RemoteCommandText.grams(45), "Pump not reachable."))
        #expect(RemoteCommandText.notification(command, now: later) != nil)
    }

    @Test("rejected before anything was saved: nothing in Loop, safe to send again")
    func rejectedBeforeSaving() {
        var command = mealCommand()
        command.apply(treatment: answer("rejected", ["kind": "mealBolus", "carbsSaved": false, "carbs": 45, "approvedUnits": 3.25], message: "Too many carbs."))
        #expect(command.phase(now: now.addingTimeInterval(60)) == .rejected)
        #expect(!command.carbsSaved)
        #expect(RemoteCommandText.detail(command, now: now.addingTimeInterval(60)) == Self.nothingSaved("Too many carbs."))
    }

    @Test("uncertain delivery keeps the carbs saved and treats the bolus as maybe given")
    func uncertainDelivery() {
        var command = mealCommand()
        command.apply(treatment: answer("uncertain", ["kind": "mealBolus", "carbsSaved": true, "carbs": 45, "approvedUnits": 3.25, "deliveredUnits": 3.2]))
        let later = now.addingTimeInterval(60)
        #expect(command.phase(now: later) == .uncertain)
        #expect(command.carbsSaved)
        #expect(command.mayStillDeliver(now: later))
        #expect(RemoteCommandText.detail(command, now: later) != Self.nothingSaved(""))
    }

    @Test("a smaller bolus than approved in Nightscout is this meal's, a larger one is not")
    func matchingSmallerBolus() {
        let command = mealCommand()
        #expect(command.couldHaveGiven(units: 3.2))
        #expect(command.couldHaveGiven(units: 3.25))
        #expect(!command.couldHaveGiven(units: 3.4))
        let found = RemoteCommandInbox.matches(commands: [command], boluses: [(now.addingTimeInterval(120), 3.2)])
        #expect(found["M1"] == now.addingTimeInterval(120))

        var answered = command
        answered.apply(treatment: answer("running", ["kind": "mealBolus", "carbsSaved": true, "deliveredUnits": 3.1]))
        #expect(answered.couldHaveGiven(units: 3.1))
        #expect(!answered.couldHaveGiven(units: 3.2))
        #expect(DoseGuard.isOwn(LoggedDose(date: now.addingTimeInterval(60), units: 3.1, source: .remote), commands: [answered]))
    }

    @Test("saved commands decode with and without meal details")
    func codable() throws {
        var command = mealCommand()
        command.apply(treatment: answer("done", ["kind": "mealBolus", "carbsSaved": true, "deliveredUnits": 3.2]))
        let data = try JSONEncoder().encode([command])
        let decoded = try JSONDecoder().decode([QueuedRemoteCommand].self, from: data)
        #expect(decoded == [command])

        let old = #"[{"commandId":"A","summary":"Bolus 1 E","units":1,"sentAt":0,"expiration":600,"status":"done"}]"#
        let plain = try JSONDecoder().decode([QueuedRemoteCommand].self, from: Data(old.utf8))
        #expect(plain.first?.meal == nil)
    }

    // MARK: History

    @Test("a meal bolus sent from here counts as the last bolus for the recommendation and the guard")
    func recordedAsBolus() {
        let storage = Storage.shared
        let savedMeals = storage.remoteMealHistory.value
        let savedBoluses = storage.remoteBolusHistory.value
        defer {
            storage.remoteMealHistory.value = savedMeals
            storage.remoteBolusHistory.value = savedBoluses
        }
        storage.remoteMealHistory.value = []
        storage.remoteBolusHistory.value = []
        let sent = Date().addingTimeInterval(-30)
        QuickPickMealsManager.shared.recordMeal(carbs: 45, bolus: 3.25, at: sent)
        let last = RecommendedBolus.lastBolusAt() ?? 0
        #expect(abs(last - sent.timeIntervalSince1970) < 1)
    }
}
