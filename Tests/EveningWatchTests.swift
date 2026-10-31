// LoopFollow
// EveningWatchTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop's evening watch as LoopFollow reads it from Nightscout. The documents are the ones Loop's
/// `EveningWatchTreatment` writes.
struct EveningWatchTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func suggestion(id: String = "e1", made: Date = now.addingTimeInterval(-25 * 60)) -> [String: AnyObject] {
        [
            "_id": "ns-\(id)",
            "eventType": "AI Bolus Suggestion",
            "source": "eveningWatch",
            "trigger": "rising",
            "created_at": iso(made), "timestamp": iso(made),
            "expiresAt": iso(made.addingTimeInterval(3 * 3600)),
            "suggestionID": id,
            "units": 0.25,
            "reason": "9,3 og opp 1,1 siste halvtime. 0,26 E om bord.",
            "glucose": 9.3,
            "mealName": "🌙 Kveldsvakt",
            "enteredBy": "Loop",
        ] as [String: Any] as [String: AnyObject]
    }

    private static func doseNote(id: String = "a1", at date: Date = now.addingTimeInterval(-10 * 60), state: String = "given") -> [String: AnyObject] {
        [
            "eventType": "Note",
            "source": "eveningWatch",
            "actionID": id,
            "created_at": iso(date), "timestamp": iso(date),
            "units": 0.2,
            "glucose": 10.0,
            "state": state,
            "enteredBy": "Loop",
            "notes": "🌙 Kveldsvakten ga 0,2 E: 10,0 og opp 0,9 siste halvtime.",
        ] as [String: Any] as [String: AnyObject]
    }

    private static func log(at date: Date) -> [String: AnyObject] {
        [
            "eventType": "Evening Watch Log",
            "source": "eveningWatch",
            "created_at": iso(date), "timestamp": iso(date),
            "mode": "automatic",
            "learnedUnits": 0.45,
            "actions": [
                ["id": "a1", "kind": "automatic", "trigger": "rising", "date": iso(date.addingTimeInterval(6900)), "glucose": 9.1, "units": 0.25, "state": "given", "givenUnits": 0.25, "iob": 0.26],
            ],
            "entries": [
                ["date": iso(date.addingTimeInterval(300)), "kind": "belowLimit", "glucose": 7.6],
                ["date": iso(date.addingTimeInterval(6900)), "kind": "dosed", "glucose": 9.1, "value": 0.25],
                ["date": iso(date.addingTimeInterval(7200)), "kind": "recentBolus", "glucose": 9.3, "until": iso(date.addingTimeInterval(10500))],
            ],
        ] as [String: Any] as [String: AnyObject]
    }

    @Test("#suggestion — the evening watch's is read as one and stays for hours")
    func suggestion() throws {
        let suggestion = try #require(AIBolusSuggestion(treatment: Self.suggestion(), now: Self.now))
        #expect(suggestion.isEveningWatch)
        #expect(suggestion.nsID == "ns-e1")
        #expect(suggestion.expiresAt > Self.now.addingTimeInterval(2 * 3600))
        #expect(AIBolusSuggestionText.title(suggestion).contains("🌙"))
        #expect(AIBolusSuggestionText.lapses(suggestion) == EveningWatchText.staysHint)
    }

    @Test("#alarm — sounds for an open evening watch suggestion, not for the meal watch's")
    func alarm() {
        let store = AIBolusSuggestionStore(defaults: UserDefaults(suiteName: "EveningWatchTests.alarm")!)
        var meal = Self.suggestion(id: "m1")
        meal.removeValue(forKey: "source")
        store.update(AIBolusSuggestion.parse([meal], now: Self.now), now: Self.now)
        #expect(store.openEveningWatch(now: Self.now) == nil)

        store.update(AIBolusSuggestion.parse([meal, Self.suggestion()], now: Self.now), now: Self.now)
        let open = store.openEveningWatch(now: Self.now)
        #expect(open?.id == "e1")
        #expect(open?.units == 0.25)

        var data = AlarmData.withBattery(nil)
        data.eveningWatch = open
        #expect(EveningWatchCondition().evaluate(alarm: Alarm(type: .eveningWatch), data: data, now: Self.now))
        data.eveningWatch = nil
        #expect(!EveningWatchCondition().evaluate(alarm: Alarm(type: .eveningWatch), data: data, now: Self.now))
    }

    @Test("#hide — a suggestion hidden here is no longer open for the alarm")
    func hidden() throws {
        let store = AIBolusSuggestionStore(defaults: UserDefaults(suiteName: "EveningWatchTests.hidden")!)
        store.update(AIBolusSuggestion.parse([Self.suggestion()], now: Self.now), now: Self.now)
        let suggestion = try #require(store.visible(now: Self.now).first)
        store.hide(suggestion, at: Self.now)
        #expect(store.openEveningWatch(now: Self.now) == nil)
    }

    @Test("#log — reads tonight's log and takes the newest")
    func log() throws {
        let older = Self.log(at: Self.now.addingTimeInterval(-86400))
        let newest = Self.log(at: Self.now.addingTimeInterval(-3 * 3600))
        let log = try #require(EveningWatch.latestLog(in: [older, newest, Self.doseNote()]))
        #expect(abs(log.date.timeIntervalSince(Self.now.addingTimeInterval(-3 * 3600))) < 1)
        #expect(log.mode == "automatic")
        #expect(log.learnedUnits == 0.45)
        #expect(log.actions.count == 1)
        #expect(log.actions[0].isAutomatic)
        #expect(log.actions[0].givenUnits == 0.25)
        #expect(log.entries.map(\.kind) == ["belowLimit", "dosed", "recentBolus"])
        #expect(log.entries[2].until != nil)
    }

    @Test("#doses — each automatic dose is announced once, and only recent ones")
    func doses() {
        let notes = [Self.doseNote(id: "a1"), Self.doseNote(id: "a2", state: "failed"), Self.doseNote(id: "old", at: Self.now.addingTimeInterval(-3 * 3600))]
        let fresh = EveningWatch.newDoseNotes(in: notes, announced: [], now: Self.now)
        #expect(fresh.map(\.actionID) == ["a1", "a2"])
        #expect(fresh[0].given)
        #expect(!fresh[1].given)
        #expect(EveningWatch.newDoseNotes(in: notes, announced: ["a1", "a2"], now: Self.now).isEmpty)

        var other = Self.doseNote()
        other.removeValue(forKey: "source")
        #expect(EveningWatch.newDoseNotes(in: [other], announced: [], now: Self.now).isEmpty)
    }

    @Test("#settings — Loop's settings from the profile")
    func settings() throws {
        let json = #"{"mode":"automatic","start":1230,"end":60,"lateFrom":1380,"risingFromMmol":9,"highFromMmol":11,"startUnits":0.5,"maximumIOB":1,"maximumPerEvening":1.2,"dosesPerEvening":3,"minutesBetween":75,"maximumUnits":0.8,"learnedUnits":0.45}"#
        let settings = try JSONDecoder().decode(EveningWatch.LoopSettings.self, from: Data(json.utf8))
        #expect(settings.mode == .automatic)
        #expect(EveningWatchText.clock(settings.start ?? 0) == "20:30")
        #expect(settings.learnedUnits == 0.45)
    }
}
