// LoopFollow
// EveningWatch.swift

import Foundation
import UserNotifications

/// The evening watch («Kveldsvakt») runs in Loop on Walter's phone: in the evening, when glucose
/// keeps rising or stays high and nothing has been given or eaten for a while, it suggests a
/// correction or, in automatic mode, gives it. LoopFollow shows what it does, from Nightscout:
///
/// - an open suggestion is an "AI Bolus Suggestion" with `source: "eveningWatch"` (see
///   `AIBolusSuggestion`); it stays on the main screen until it is given, declined here or in
///   Loop, or no longer needed. Declining here deletes it, which Loop takes as declined.
/// - an automatic dose is a "Note" with `source: "eveningWatch"` (`DoseNote`).
/// - tonight's log is one "Evening Watch Log" treatment (`Log`), replaced as it grows.
/// - its settings come with Loop's settings in the profile (`loopSettings.eveningWatch`).
///
/// Contract in Loop's `EveningWatchManager.swift` (`EveningWatchTreatment`); change both apps
/// together. Glucose is in mmol/L.
enum EveningWatch {
    static let source = "eveningWatch"
    static let logEventType = "Evening Watch Log"

    /// The settings as Loop uploads them.
    struct LoopSettings: Codable, Equatable {
        enum Mode: String, Codable {
            case off, suggest, automatic
        }

        struct Stop: Codable, Equatable {
            var date: String?
            var lowestMmol: Double?
        }

        var mode: Mode?
        /// Minutes after midnight.
        var start: Int?
        var end: Int?
        var lateFrom: Int?
        var risingFromMmol: Double?
        var highFromMmol: Double?
        var startUnits: Double?
        var maximumIOB: Double?
        var maximumPerEvening: Double?
        var dosesPerEvening: Int?
        var minutesBetween: Int?
        var maximumUnits: Double?
        var learnedUnits: Double?
        var stop: Stop?
    }

    /// An open suggestion, for the alarm.
    struct Open: Codable, Equatable {
        var id: String
        var units: Double
        var reason: String
    }

    /// Tonight's log from Loop.
    struct Log: Codable, Equatable {
        struct Action: Codable, Equatable, Identifiable {
            var id: String
            var kind: String
            var trigger: String?
            var date: Date
            var glucose: Double?
            var units: Double
            var state: String
            var givenUnits: Double?
            var iob: Double?
            var change30: Double?

            var isAutomatic: Bool { kind == "automatic" }
        }

        struct Entry: Codable, Equatable {
            var date: Date
            var kind: String
            var glucose: Double?
            var until: Date?
            var value: Double?
        }

        var date: Date
        var mode: String?
        var learnedUnits: Double?
        var actions: [Action]
        var entries: [Entry]

        init(date: Date, mode: String?, learnedUnits: Double?, actions: [Action], entries: [Entry]) {
            self.date = date
            self.mode = mode
            self.learnedUnits = learnedUnits
            self.actions = actions
            self.entries = entries
        }

        /// Reads the treatment; nil when it is another kind or has no date.
        init?(treatment entry: [String: AnyObject]) {
            guard entry["eventType"] as? String == EveningWatch.logEventType,
                  let dateString = (entry["created_at"] as? String) ?? (entry["timestamp"] as? String),
                  let date = NightscoutUtils.parseDate(dateString)
            else { return nil }
            self.date = date
            mode = entry["mode"] as? String
            learnedUnits = EveningWatch.number(entry["learnedUnits"])
            actions = (entry["actions"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let kind = item["kind"] as? String, let state = item["state"] as? String,
                      let date = (item["date"] as? String).flatMap(NightscoutUtils.parseDate),
                      let units = EveningWatch.number(item["units"])
                else { return nil }
                return Action(id: id, kind: kind, trigger: item["trigger"] as? String, date: date, glucose: EveningWatch.number(item["glucose"]),
                              units: units, state: state, givenUnits: EveningWatch.number(item["givenUnits"]), iob: EveningWatch.number(item["iob"]),
                              change30: EveningWatch.number(item["change30"]))
            }
            entries = (entry["entries"] as? [[String: Any]] ?? []).compactMap { item in
                guard let kind = item["kind"] as? String, let date = (item["date"] as? String).flatMap(NightscoutUtils.parseDate) else { return nil }
                return Entry(date: date, kind: kind, glucose: EveningWatch.number(item["glucose"]),
                             until: (item["until"] as? String).flatMap(NightscoutUtils.parseDate), value: EveningWatch.number(item["value"]))
            }
        }
    }

    /// The note Loop writes for an automatic dose.
    struct DoseNote: Equatable {
        var actionID: String
        var date: Date
        var units: Double
        var given: Bool
        var text: String

        init?(treatment entry: [String: AnyObject]) {
            guard entry["eventType"] as? String == "Note",
                  entry["source"] as? String == EveningWatch.source,
                  let actionID = entry["actionID"] as? String,
                  let dateString = (entry["created_at"] as? String) ?? (entry["timestamp"] as? String),
                  let date = NightscoutUtils.parseDate(dateString),
                  let units = EveningWatch.number(entry["units"])
            else { return nil }
            self.actionID = actionID
            self.date = date
            self.units = units
            given = entry["state"] as? String == "given"
            text = (entry["notes"] as? String) ?? ""
        }
    }

    /// The newest log among the treatments.
    static func latestLog(in entries: [[String: AnyObject]]) -> Log? {
        entries.compactMap(Log.init(treatment:)).max { $0.date < $1.date }
    }

    /// Notes for automatic doses not announced yet, within the last two hours.
    static func newDoseNotes(in notes: [[String: AnyObject]], announced: Set<String>, now: Date) -> [DoseNote] {
        notes.compactMap(DoseNote.init(treatment:))
            .filter { !announced.contains($0.actionID) && now.timeIntervalSince($0.date) < 2 * 3600 }
            .sorted { $0.date < $1.date }
    }

    static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let double = value as? Double { number = double }
        else if let int = value as? Int { number = Double(int) }
        else if let string = value as? String { number = Double(string) }
        else { number = nil }
        guard let number, number.isFinite else { return nil }
        return number
    }
}

extension MainViewController {
    /// Tonight's log for the settings screen, and a quiet notification for each automatic dose.
    func processNSEveningWatch(logs: [[String: AnyObject]], notes: [[String: AnyObject]], now: Date = Date()) {
        if let log = EveningWatch.latestLog(in: logs), log != Storage.shared.eveningWatchLog.value {
            Storage.shared.eveningWatchLog.value = log
        }
        let announced = Storage.shared.eveningWatchAnnounced.value
        let fresh = EveningWatch.newDoseNotes(in: notes, announced: Set(announced), now: now)
        guard !fresh.isEmpty else { return }
        for note in fresh {
            let content = UNMutableNotificationContent()
            content.title = EveningWatchText.doseNotificationTitle(note)
            // Loop's note is "title: why"; the why is enough under the title.
            content.body = note.text.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            content.interruptionLevel = .passive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "eveningWatchDose-\(note.actionID)", content: content, trigger: nil))
            LogManager.shared.log(category: .alarm, message: "Evening watch dose \(note.actionID): \(note.units) U, given \(note.given)")
        }
        Storage.shared.eveningWatchAnnounced.value = Array((announced + fresh.map(\.actionID)).suffix(50))
    }
}
