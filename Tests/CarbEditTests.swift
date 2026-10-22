// LoopFollow
// CarbEditTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop finds a carb entry to change by the `syncIdentifier` it uploads with it. These pin which
/// Nightscout treatments can be edited and that only the changed values are sent.
struct CarbEditTests {
    /// 2026-10-22 12:00:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_670_400)

    private static func treatment(_ overrides: [String: AnyObject] = [:], dropping keys: Set<String> = []) -> [String: AnyObject] {
        var entry: [String: AnyObject] = [
            "_id": "65f0c0ffee0000000000abcd" as NSString,
            "eventType": "Carb Correction" as NSString,
            "timestamp": "2026-10-22T11:30:00.000Z" as NSString,
            "carbs": NSNumber(value: 30),
            "absorptionTime": NSNumber(value: 180),
            "foodType": "🍕 Pizza" as NSString,
            "syncIdentifier": "ABC-123" as NSString,
            "enteredBy": "loop://iPhone" as NSString,
        ]
        for key in keys {
            entry.removeValue(forKey: key)
        }
        entry.merge(overrides) { _, new in new }
        return entry
    }

    private static var entry: LoggedCarbEntry {
        LoggedCarbEntry.parse([treatment()], now: now)[0]
    }

    @Test func parsesLoopsCarbEntry() throws {
        let entries = LoggedCarbEntry.parse([Self.treatment()], now: Self.now)
        let entry = try #require(entries.first)
        #expect(entry.syncIdentifier == "ABC-123")
        #expect(entry.grams == 30)
        #expect(entry.absorptionMinutes == 180)
        #expect(entry.foodType == "🍕 Pizza")
        #expect(entry.date == Self.now.addingTimeInterval(-30 * 60))
    }

    @Test func skipsEntriesLoopCannotFind() {
        let careportal = Self.treatment(dropping: ["syncIdentifier"])
        let old = Self.treatment(["timestamp": "2026-10-21T11:00:00.000Z" as NSString, "syncIdentifier": "OLD" as NSString])
        #expect(LoggedCarbEntry.parse([careportal, old], now: Self.now).isEmpty)
    }

    @Test func newestFirst() {
        let earlier = Self.treatment(["timestamp": "2026-10-22T08:00:00.000Z" as NSString, "syncIdentifier": "EARLY" as NSString])
        let ids = LoggedCarbEntry.parse([earlier, Self.treatment()], now: Self.now).map(\.id)
        #expect(ids == ["ABC-123", "EARLY"])
    }

    @Test func unchangedDraftSendsNothing() {
        #expect(CarbEditDraft(entry: Self.entry).changes(from: Self.entry) == nil)
    }

    @Test func sendsOnlyTheChangedAmount() throws {
        var draft = CarbEditDraft(entry: Self.entry)
        draft.grams = 45
        let block = try #require(draft.changes(from: Self.entry))
        #expect(Set(block.keys) == ["sync-identifier", "carbs"])
        #expect(block["carbs"] as? Double == 45)
        #expect(block["sync-identifier"] as? String == "ABC-123")
    }

    @Test func sendsTimeAbsorptionAndFood() throws {
        var draft = CarbEditDraft(entry: Self.entry)
        draft.date = Self.entry.date.addingTimeInterval(15 * 60)
        draft.absorptionHours = 4.5
        draft.emoji = "🌮"
        draft.name = "Taco"
        let block = try #require(draft.changes(from: Self.entry))
        #expect(block["start-time"] as? String == "2026-10-22T11:45:00.000Z")
        #expect(block["absorption-time"] as? Double == 4.5)
        #expect(block["food-type"] as? String == "🌮 Taco")
        #expect(block["carbs"] == nil)
    }

    @Test func clearingTheFoodSendsAnEmptyFoodType() throws {
        var draft = CarbEditDraft(entry: Self.entry)
        draft.emoji = ""
        draft.name = ""
        let block = try #require(draft.changes(from: Self.entry))
        #expect(block["food-type"] as? String == "")
    }

    @Test func entryWithoutAbsorptionIsNotChangedByTheDefault() {
        let entry = LoggedCarbEntry.parse([Self.treatment(dropping: ["absorptionTime"])], now: Self.now)[0]
        #expect(CarbEditDraft(entry: entry).changes(from: entry) == nil)
    }

    @Test func deletion() {
        let block = CarbEditDraft.deletion(of: Self.entry)
        #expect(block["sync-identifier"] as? String == "ABC-123")
        #expect(block["delete"] as? Bool == true)
    }

    @Test func sentEntryWaitsUntilNightscoutShowsTheChange() {
        let store = LoggedCarbsStore()
        store.update(carbEntries: [Self.treatment()], now: Self.now)
        let entry = store.entries[0]
        store.markSent(entry, at: Self.now)
        #expect(store.sentAt(entry, now: Self.now) == Self.now)

        store.update(carbEntries: [Self.treatment()], now: Self.now.addingTimeInterval(60))
        #expect(store.sentAt(store.entries[0], now: Self.now.addingTimeInterval(60)) != nil)

        store.update(carbEntries: [Self.treatment(["carbs": NSNumber(value: 45)])], now: Self.now.addingTimeInterval(120))
        #expect(store.sentAt(store.entries[0], now: Self.now.addingTimeInterval(120)) == nil)
    }
}
