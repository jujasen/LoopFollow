// LoopFollow
// AIBolusSuggestionTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct AIBolusSuggestionTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A treatment as Loop's MealWatchTreatment uploads it.
    private static func treatment(id: String = "s1", units: Any = 0.4, made: Date = now.addingTimeInterval(-120), expires: Date = now.addingTimeInterval(18 * 60)) -> [String: AnyObject] {
        [
            "eventType": "AI Bolus Suggestion",
            "created_at": iso(made), "timestamp": iso(made),
            "expiresAt": iso(expires),
            "suggestionID": id,
            "units": units,
            "reason": "BS 12,4 og stiger 35 min etter melka.",
            "glucose": 12.4, "loopUnits": 0.15,
            "foodType": "🥛 Melk", "mealName": "Melk", "mealDate": iso(now.addingTimeInterval(-35 * 60)), "mealCarbs": 12,
            "enteredBy": "Loop",
        ] as [String: Any] as [String: AnyObject]
    }

    @Test("#parse — reads Loop's treatment")
    func valid() throws {
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.treatment(), now: Self.now))
        #expect(suggestion.id == "s1")
        #expect(suggestion.units == 0.4)
        #expect(suggestion.reason == "BS 12,4 og stiger 35 min etter melka.")
        #expect(suggestion.glucoseMmol == 12.4)
        #expect(suggestion.loopUnits == 0.15)
        #expect(suggestion.mealCarbs == 12)
        #expect(suggestion.meal == "🥛 Melk")
        #expect(abs(suggestion.expiresAt.timeIntervalSince(Self.now) - 18 * 60) < 1)
    }

    @Test("#parse — a lapsed suggestion is left out")
    func expired() {
        #expect(AIBolusSuggestion(treatment: Self.treatment(expires: Self.now.addingTimeInterval(-1)), now: Self.now) == nil)
    }

    @Test("#parse — missing id, amount, expiry or the wrong kind gives nothing")
    func missingFields() {
        for key in ["suggestionID", "units", "expiresAt"] {
            var entry = Self.treatment()
            entry.removeValue(forKey: key)
            #expect(AIBolusSuggestion(treatment: entry, now: Self.now) == nil, "without \(key)")
        }
        var other = Self.treatment()
        other["eventType"] = "Note" as AnyObject
        #expect(AIBolusSuggestion(treatment: other, now: Self.now) == nil)

        var noReason = Self.treatment()
        noReason.removeValue(forKey: "reason")
        noReason.removeValue(forKey: "foodType")
        #expect(AIBolusSuggestion(treatment: noReason, now: Self.now)?.reason == "", "the reason may be missing")
        #expect(AIBolusSuggestion(treatment: noReason, now: Self.now)?.meal == "Melk", "the meal name stands in for the food type")
    }

    @Test("#parse — an amount that is not a positive finite number is ignored")
    func nonFiniteUnits() {
        for units: Any in ["inf", "nan", Double.infinity, 0.0, -0.3, "abc"] {
            #expect(AIBolusSuggestion(treatment: Self.treatment(units: units), now: Self.now) == nil, "units \(units)")
        }
        #expect(AIBolusSuggestion(treatment: Self.treatment(units: "0.35"), now: Self.now)?.units == 0.35)
    }

    @Test("#parse — one per id, the newest copy")
    func duplicates() {
        let older = Self.treatment(units: 0.3, made: Self.now.addingTimeInterval(-300))
        let newer = Self.treatment(units: 0.5, made: Self.now.addingTimeInterval(-60))
        let parsed = AIBolusSuggestion.parse([older, newer, Self.treatment(id: "s2")], now: Self.now)
        #expect(parsed.count == 2)
        #expect(parsed.first { $0.id == "s1" }?.units == 0.5)
    }

    // MARK: - Store

    private func defaults() -> UserDefaults {
        let name = "AIBolusSuggestionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("#store — a new suggestion is announced once")
    func announcedOnce() throws {
        let store = AIBolusSuggestionStore(defaults: defaults())
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.treatment(), now: Self.now))
        #expect(store.update([suggestion], now: Self.now).map(\.id) == ["s1"])
        #expect(store.update([suggestion], now: Self.now.addingTimeInterval(60)).isEmpty)
    }

    @Test("#store — a declined suggestion stays hidden, also after a restart, and is forgotten after a day")
    func dismissalPersists() throws {
        let defaults = defaults()
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.treatment(), now: Self.now))
        let store = AIBolusSuggestionStore(defaults: defaults)
        store.update([suggestion], now: Self.now)
        #expect(store.visible(now: Self.now).count == 1)

        store.dismiss(suggestion, at: Self.now)
        #expect(store.visible(now: Self.now).isEmpty)

        let restarted = AIBolusSuggestionStore(defaults: defaults)
        #expect(restarted.update([suggestion], now: Self.now.addingTimeInterval(60)).isEmpty, "not announced again")
        #expect(restarted.visible(now: Self.now.addingTimeInterval(60)).isEmpty)

        restarted.update([], now: Self.now.addingTimeInterval(AIBolusSuggestionStore.memory + 60))
        #expect(restarted.dismissed.isEmpty)
    }

    @Test("#store — a lapsed suggestion is not shown, even before Nightscout is read again")
    func lapsesOnTime() throws {
        let store = AIBolusSuggestionStore(defaults: defaults())
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.treatment(), now: Self.now))
        store.update([suggestion], now: Self.now)
        #expect(store.visible(now: suggestion.expiresAt.addingTimeInterval(1)).isEmpty)
    }

    @Test("#store — a tapped notification opens the suggestion once it is read")
    func reviewFromNotification() throws {
        let store = AIBolusSuggestionStore(defaults: defaults())
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.treatment(expires: Date().addingTimeInterval(600)), now: Date()))
        store.review(id: "s1")
        #expect(store.reviewing == nil)
        store.update([suggestion])
        #expect(store.reviewing?.id == "s1")
        store.update([])
        #expect(store.reviewing == nil, "gone from Nightscout: given, declined on Loop's phone or lapsed")
    }
}
