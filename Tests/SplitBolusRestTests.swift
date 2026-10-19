// LoopFollow
// SplitBolusRestTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop uploads one "Split Bolus Rest" treatment while the rest of a split bolus waits. These pin
/// how LoopFollow reads it, when it counts as logged, and what the button sends.
struct SplitBolusRestTests {
    /// 2026-10-19 19:00:00 UTC.
    private static let now: TimeInterval = 1_792_436_400

    /// A treatment as Loop writes it: milk at 19:00, rest due 21:00, let go 23:00 (UTC).
    private static func treatment(
        dropping keys: Set<String> = [],
        _ overrides: [String: AnyObject] = [:]
    ) -> [String: AnyObject] {
        var entry: [String: AnyObject] = [
            "_id": "65f0c0ffee0000000000abcd" as NSString,
            "eventType": "Split Bolus Rest" as NSString,
            "created_at": "2026-10-19T21:00:00.000Z" as NSString,
            "timestamp": "2026-10-19T21:00:00.000Z" as NSString,
            "expiresAt": "2026-10-19T23:00:00.000Z" as NSString,
            "splitBolusID": "split-1" as NSString,
            "state": "waiting" as NSString,
            "restCarbs": NSNumber(value: 6),
            "restUnits": NSNumber(value: 0.4),
            "restFoodType": "🥛🍼 Melk (resten)" as NSString,
            "absorptionTime": NSNumber(value: 180),
            "foodType": "🥛🍼 Melk" as NSString,
            "mealName": "Melk" as NSString,
            "mealDate": "2026-10-19T19:00:00.000Z" as NSString,
            "mealCarbs": NSNumber(value: 14),
            "nowCarbs": NSNumber(value: 8),
            "enteredBy": "Loop" as NSString,
            "notes": "Rest av delt bolus 6 g · Melk" as NSString,
        ]
        for key in keys {
            entry.removeValue(forKey: key)
        }
        entry.merge(overrides) { _, new in new }
        return entry
    }

    private static func carb(_ foodType: String, at time: String) -> [String: AnyObject] {
        [
            "eventType": "Carb Correction" as NSString,
            "created_at": time as NSString,
            "carbs": NSNumber(value: 6),
            "foodType": foodType as NSString,
        ]
    }

    private static func rest(_ overrides: [String: AnyObject] = [:]) throws -> SplitBolusRest {
        try #require(SplitBolusRest(treatment: treatment(overrides), now: now))
    }

    // MARK: Reading the treatment

    @Test func readsTheRestAsLoopWritesIt() throws {
        let rest = try Self.rest()
        #expect(rest.id == "split-1")
        #expect(rest.dueDate == Self.now + 2 * 3600)
        #expect(rest.expiresAt == Self.now + 4 * 3600)
        #expect(rest.state == .waiting)
        #expect(rest.grams == 6)
        #expect(rest.units == 0.4)
        #expect(rest.restFoodType == "🥛🍼 Melk (resten)")
        #expect(rest.absorptionTime == 180)
        #expect(rest.foodType == "🥛🍼 Melk")
        #expect(rest.mealName == "Melk")
        #expect(rest.mealDate == Self.now)
        #expect(rest.mealCarbs == 14)
        #expect(rest.nowCarbs == 8)
    }

    @Test func readsTheState() throws {
        #expect(try Self.rest(["state": "due" as NSString]).state == .due)
        #expect(try Self.rest(["state": "postponed" as NSString]).state == .postponed)
        #expect(try Self.rest(["state": "something new" as NSString]).state == .waiting)
    }

    @Test func skipsWhatIsNotAWaitingRest() {
        #expect(SplitBolusRest(treatment: Self.treatment(["eventType": "Planned Carbs" as NSString]), now: Self.now) == nil)
        #expect(SplitBolusRest(treatment: Self.treatment(dropping: ["restCarbs"]), now: Self.now) == nil)
        #expect(SplitBolusRest(treatment: Self.treatment(dropping: ["expiresAt"]), now: Self.now) == nil)
        #expect(SplitBolusRest(treatment: Self.treatment(), now: Self.now + 4 * 3600 + 1) == nil, "let go")
    }

    @Test func fillsInWhatAnOlderLoopLeftOut() throws {
        let rest = try #require(SplitBolusRest(treatment: Self.treatment(dropping: ["restFoodType", "absorptionTime", "restUnits", "mealName"]), now: Self.now))
        #expect(rest.restFoodType == "🥛🍼 Melk (rest)")
        #expect(rest.absorptionTime == 180)
        #expect(rest.units == nil)
        #expect(rest.mealName == "Melk")
    }

    @Test func parsesEarliestFirst() {
        let later = Self.treatment(["splitBolusID": "split-2" as NSString, "timestamp": "2026-10-19T21:30:00.000Z" as NSString])
        let rests = SplitBolusRest.parse([later, Self.treatment()], now: Self.now)
        #expect(rests.map(\.id) == ["split-1", "split-2"])
    }

    // MARK: Logged or not

    @Test func aCarbEntryWithTheRestsNameSinceTheMealMeansItIsLogged() throws {
        let rest = try Self.rest()
        #expect(rest.isLogged(in: [Self.carb("🥛🍼 Melk (resten)", at: "2026-10-19T21:05:00.000Z")]))
        #expect(!rest.isLogged(in: [Self.carb("🥛🍼 Melk", at: "2026-10-19T19:00:00.000Z")]), "the first part")
        #expect(!rest.isLogged(in: [Self.carb("🥛🍼 Melk (resten)", at: "2026-10-18T21:05:00.000Z")]), "yesterday's rest")
        #expect(!rest.isLogged(in: []))
    }

    @Test func aLoggedRestIsNotShown() throws {
        let rest = try Self.rest()
        #expect(SplitBolusRestStore.visible([rest], carbEntries: []) == [rest])
        #expect(SplitBolusRestStore.visible([rest], carbEntries: [Self.carb("🥛🍼 Melk (resten)", at: "2026-10-19T21:05:00.000Z")]).isEmpty)
    }

    // MARK: Sending

    @Test func theButtonSendsTheRestAsLoopNamesIt() throws {
        let rest = try Self.rest()
        let date = Date(timeIntervalSince1970: Self.now + 2 * 3600)
        let payload = rest.payload(otp: "123456", at: date)
        #expect(payload.type == .carbs)
        #expect(payload.carbsAmount == 6)
        #expect(payload.absorptionTime == 3.0)
        #expect(payload.foodType == "🥛🍼 Melk (resten)")
        #expect(payload.consumedDate == date)
        #expect(payload.otp == "123456")
        #expect(payload.bolusAmount == nil, "carbs only: Loop doses for them")
    }

    @Test func aRestOverTheCarbLimitIsNotSent() throws {
        let rest = try Self.rest(["restCarbs": NSNumber(value: 40)])
        #expect(SplitBolusRestSender.problem(with: rest, maxCarbs: 30) != nil)
    }

    @Test func aSentRestHoldsForAQuarterOfAnHour() throws {
        let defaults = try #require(UserDefaults(suiteName: "SplitBolusRestTests"))
        defaults.removePersistentDomain(forName: "SplitBolusRestTests")
        let store = SplitBolusRestStore(defaults: defaults)
        let rest = try Self.rest()
        let sent = Date(timeIntervalSince1970: Self.now + 2 * 3600)
        store.update(rests: [rest], carbEntries: [], now: sent)
        store.markSent(rest, at: sent)

        #expect(store.sentAt(rest, now: sent.addingTimeInterval(60)) == sent)
        #expect(SplitBolusRestStore(defaults: defaults).sentAt(rest, now: sent.addingTimeInterval(60)) == sent, "kept across launches")
        #expect(store.sentAt(rest, now: sent.addingTimeInterval(16 * 60)) == nil, "can be sent again")

        // Gone from Nightscout: forgotten once the hold is over.
        store.update(rests: [], carbEntries: [], now: sent.addingTimeInterval(16 * 60))
        #expect(store.sent.isEmpty)
        #expect(store.rests.isEmpty)
    }

    // MARK: Chart and card

    @Test func thePillNamesTheRestAndItsWindow() {
        let text = BGChartModel.splitBolusRestPillText(food: CarbFoodLabel(foodType: "🥛🍼 Melk"), grams: 6, units: "0.4", window: ("21:00", "23:00"))
        #expect(text == "Rest ✂️ 🥛🍼\nMelk\n6g ≈0.4U\n21:00–23:00")
        let bare = BGChartModel.splitBolusRestPillText(food: CarbFoodLabel(foodType: nil), grams: 6, units: nil, window: ("21:00", "23:00"))
        #expect(bare == "Rest ✂️\n6g\n21:00–23:00")
    }

    @Test func theConfirmationWarnsWhenItIsEarlyOrHeldBack() throws {
        let due = SplitBolusRestText.confirmation(try Self.rest(["state": "due" as NSString]))
        let early = SplitBolusRestText.confirmation(try Self.rest())
        let held = SplitBolusRestText.confirmation(try Self.rest(["state": "postponed" as NSString]))
        #expect(due.contains("🥛🍼 Melk (resten)"))
        #expect(!due.contains("\n\n"))
        #expect(early.contains("\n\n"))
        #expect(held.contains("\n\n"))
        #expect(early != held)
    }
}
