// LoopFollow
// LowWatchTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop's low watch as LoopFollow reads it from Nightscout. The documents are the ones Loop's
/// `LowWatchTreatment` writes.
struct LowWatchTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func suggestion(id: String = "l1", made: Date = now.addingTimeInterval(-3 * 60), grams: Double = 3) -> [String: AnyObject] {
        [
            "_id": "ns-\(id)",
            "eventType": "Low Watch Suggestion",
            "source": "lowWatch",
            "trigger": "forecast",
            "created_at": iso(made), "timestamp": iso(made),
            "expiresAt": iso(made.addingTimeInterval(30 * 60)),
            "suggestionID": id,
            "grams": grams,
            "glucose": 5.3,
            "lowestForecast": 3.6,
            "reason": "Hvorfor: 5,3, og Loop spår 3,6 innen 20 min.",
            "enteredBy": "Loop",
        ] as [String: Any] as [String: AnyObject]
    }

    @Test("#read — the newest open suggestion, not lapsed ones or other treatments")
    func read() throws {
        let older = Self.suggestion(id: "old", made: Self.now.addingTimeInterval(-10 * 60))
        let newest = Self.suggestion(id: "new")
        let lapsed = Self.suggestion(id: "lapsed", made: Self.now.addingTimeInterval(-40 * 60))
        let carbs = ["eventType": "Carb Correction", "carbs": 4, "created_at": Self.iso(Self.now)] as [String: Any] as [String: AnyObject]
        let latest = try #require(LowWatchSuggestion.latest(in: [older, lapsed, newest, carbs], now: Self.now))
        #expect(latest.id == "new")
        #expect(latest.grams == 3)
        #expect(latest.nsID == "ns-new")
        #expect(latest.reason.contains("3,6"))
        #expect(LowWatchSuggestion.latest(in: [lapsed], now: Self.now) == nil)
    }

    @Test("#announce — notified once, then not again")
    func announce() {
        let store = LowWatchStore(defaults: UserDefaults(suiteName: "LowWatchTests.announce")!)
        defer { UserDefaults().removePersistentDomain(forName: "LowWatchTests.announce") }
        let latest = LowWatchSuggestion.latest(in: [Self.suggestion()], now: Self.now)
        #expect(store.update(latest, carbs: [], now: Self.now)?.id == "l1")
        #expect(store.update(latest, carbs: [], now: Self.now.addingTimeInterval(60)) == nil)
        #expect(store.visible(now: Self.now)?.id == "l1")
    }

    @Test("#answered — carbs entered after it hide it at once; earlier carbs do not")
    func answered() {
        let store = LowWatchStore(defaults: UserDefaults(suiteName: "LowWatchTests.answered")!)
        defer { UserDefaults().removePersistentDomain(forName: "LowWatchTests.answered") }
        let latest = LowWatchSuggestion.latest(in: [Self.suggestion()], now: Self.now)
        let before = [(date: Self.now.addingTimeInterval(-30 * 60), grams: 20.0)]
        #expect(store.update(latest, carbs: before, now: Self.now) != nil)
        #expect(store.visible(now: Self.now) != nil)

        let after = [(date: Self.now.addingTimeInterval(-60), grams: 3.0)]
        #expect(store.update(latest, carbs: after, now: Self.now) == nil)
        #expect(store.visible(now: Self.now) == nil)
    }

    @Test("#decline — hidden here")
    func decline() throws {
        let store = LowWatchStore(defaults: UserDefaults(suiteName: "LowWatchTests.decline")!)
        defer { UserDefaults().removePersistentDomain(forName: "LowWatchTests.decline") }
        var suggestion = try #require(LowWatchSuggestion.latest(in: [Self.suggestion()], now: Self.now))
        suggestion.nsID = nil
        store.update(suggestion, carbs: [], now: Self.now)
        store.decline(suggestion, at: Self.now)
        #expect(store.visible(now: Self.now) == nil)
    }

    @Test("#title — the grams in the title")
    func title() {
        #expect(LowWatchText.title(grams: 4).contains("4"))
        #expect(LowWatchText.title(grams: 4).hasPrefix(LowWatchText.symbol))
    }
}
