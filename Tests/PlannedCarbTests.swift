// LoopFollow
// PlannedCarbTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop uploads one "Planned Carbs" treatment per waiting later-carbs plan. These pin how
/// LoopFollow reads it — and that it is never mistaken for a carb entry.
struct PlannedCarbTests {
    /// 2026-10-02 19:00:00 UTC.
    private static let now: TimeInterval = 1_790_967_600

    /// A treatment as Loop writes it: due 19:30, expires 21:00 (UTC).
    private static func treatment(
        dropping keys: Set<String> = [],
        _ overrides: [String: AnyObject] = [:]
    ) -> [String: AnyObject] {
        var entry: [String: AnyObject] = [
            "_id": "65f0c0ffee0000000000abcd" as NSString,
            "eventType": "Planned Carbs" as NSString,
            "created_at": "2026-10-02T19:30:00.000Z" as NSString,
            "timestamp": "2026-10-02T19:30:00.000Z" as NSString,
            "plannedCarbs": NSNumber(value: 6),
            "absorptionTime": NSNumber(value: 180),
            "expiresAt": "2026-10-02T21:00:00.000Z" as NSString,
            "foodType": "🥛 Melk" as NSString,
            "notes": "Senere karbo 6 g · Melk" as NSString,
            "reason": "Fett og protein fra melken" as NSString,
            "plannedCarbsID": "meal-42" as NSString,
            "enteredBy": "Loop" as NSString,
        ]
        for key in keys {
            entry.removeValue(forKey: key)
        }
        entry.merge(overrides) { _, new in new }
        return entry
    }

    @Test("reads a plan Loop uploaded")
    func valid() throws {
        let plan = try #require(PlannedCarb(treatment: Self.treatment(), now: Self.now))
        #expect(plan.id == "meal-42")
        #expect(plan.dueDate == Self.now + 30 * 60)
        #expect(plan.expiresAt == Self.now + 2 * 3600)
        #expect(plan.grams == 6)
        #expect(plan.absorptionTime == 180)
        #expect(plan.foodType == "🥛 Melk")
        #expect(plan.reason == "Fett og protein fra melken")
        #expect(CarbFoodLabel(foodType: plan.foodType) == CarbFoodLabel(emoji: "🥛", name: "Melk"))
    }

    @Test("falls back to created_at when timestamp is missing")
    func createdAtFallback() throws {
        let plan = try #require(PlannedCarb(treatment: Self.treatment(dropping: ["timestamp"]), now: Self.now))
        #expect(plan.dueDate == Self.now + 30 * 60)
    }

    @Test("optional fields may be absent")
    func optionalFields() throws {
        let plan = try #require(PlannedCarb(
            treatment: Self.treatment(dropping: ["reason", "foodType", "absorptionTime", "plannedCarbsID", "notes"]),
            now: Self.now
        ))
        #expect(plan.reason == nil)
        #expect(plan.foodType == nil)
        #expect(plan.absorptionTime == 0)
        #expect(plan.id == "65f0c0ffee0000000000abcd")
    }

    @Test("a plan without a time, expiry or grams is skipped",
          arguments: [["timestamp", "created_at"], ["expiresAt"], ["plannedCarbs"]])
    func missingRequired(keys: [String]) {
        #expect(PlannedCarb(treatment: Self.treatment(dropping: Set(keys)), now: Self.now) == nil)
    }

    @Test("zero grams or an unreadable date is skipped")
    func badValues() {
        #expect(PlannedCarb(treatment: Self.treatment(["plannedCarbs": NSNumber(value: 0)]), now: Self.now) == nil)
        #expect(PlannedCarb(treatment: Self.treatment(["expiresAt": "soon" as NSString]), now: Self.now) == nil)
    }

    @Test("an expired plan is dropped")
    func expired() {
        #expect(PlannedCarb(treatment: Self.treatment(), now: Self.now + 2 * 3600) == nil)
        #expect(PlannedCarb(treatment: Self.treatment(), now: Self.now + 3 * 3600) == nil)
        // Past its due time but not yet expired: still waiting.
        #expect(PlannedCarb(treatment: Self.treatment(), now: Self.now + 3600) != nil)
    }

    @Test("a plan is never read as carbs, and carbs are never read as a plan")
    func noCarbsSideEffects() {
        // Loop leaves `carbs` out on purpose, so the carb readers (today's carbs, the carb dots,
        // stats) all skip the plan.
        #expect(Self.treatment()["carbs"] == nil)

        let carbEntry: [String: AnyObject] = [
            "eventType": "Carb Correction" as NSString,
            "created_at": "2026-10-02T18:00:00.000Z" as NSString,
            "carbs": NSNumber(value: 30),
            "plannedCarbs": NSNumber(value: 6),
            "expiresAt": "2026-10-02T21:00:00.000Z" as NSString,
        ]
        let plans = PlannedCarb.parse([carbEntry, Self.treatment()], now: Self.now)
        #expect(plans.map(\.id) == ["meal-42"])
        #expect(plans.map(\.grams) == [6])
    }

    @Test("plans come back in due order")
    func sorted() {
        let later = Self.treatment([
            "timestamp": "2026-10-02T20:15:00.000Z" as NSString,
            "plannedCarbsID": "meal-43" as NSString,
        ])
        #expect(PlannedCarb.parse([later, Self.treatment()], now: Self.now).map(\.id) == ["meal-42", "meal-43"])
    }

    @Test("chart pill shows the meal, the grams and the window")
    func chartPill() {
        #expect(BGChartModel.plannedCarbPillText(food: CarbFoodLabel(foodType: "🥛 Melk"), grams: 6, window: ("21:30", "23:00"))
            == "Later carbs 🥛\nMelk\n6g\n21:30–23:00")
        #expect(BGChartModel.plannedCarbPillText(food: CarbFoodLabel(foodType: nil), grams: 6, window: ("21:30", "23:00"))
            == "Later carbs\n6g\n21:30–23:00")
    }
}
