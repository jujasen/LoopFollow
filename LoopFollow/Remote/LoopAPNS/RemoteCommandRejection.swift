// LoopFollow
// RemoteCommandRejection.swift

import Foundation
import UserNotifications

/// Loop answers a remote command it refuses (a password that has expired, a bolus over the
/// maximum, …) with a Nightscout "Note": `enteredBy` names the command in Loop's language
/// ("Bolus-oppføring 0,5 E") and `notes` is Loop's error, a newline and the push it got
/// (NightscoutService.swift, `commandSourceV1(_:uploadError:notification:)`). Apple accepting
/// the push is all LoopFollow learns when it sends, so this note is the only sign that a
/// command was never carried out.
struct RemoteCommandRejection: Equatable {
    let noteDate: Date
    let command: String
    let error: String
    let sentAt: Date?

    init?(treatment: [String: AnyObject]) {
        guard treatment["eventType"] as? String == "Note",
              let notes = treatment["notes"] as? String,
              let jsonStart = notes.firstIndex(of: "{"),
              let data = String(notes[jsonStart...]).data(using: .utf8),
              let push = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              push["remote-address"] as? String == "LoopFollow" || push["entered-by"] as? String == "LoopFollow",
              let dateString = (treatment["created_at"] as? String) ?? (treatment["timestamp"] as? String),
              let noteDate = NightscoutUtils.parseDate(dateString)
        else { return nil }

        self.noteDate = noteDate
        error = notes[..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredBy = (treatment["enteredBy"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        command = enteredBy.isEmpty ? String(localized: "Remote command", table: "RemoteCommandRejection", comment: "Name of a remote command Loop rejected when Loop did not name it") : enteredBy
        sentAt = (push["sent-at"] as? String).flatMap(NightscoutUtils.parseDate)
    }

    /// How long the push took to reach the phone with Loop.
    var delay: TimeInterval? {
        sentAt.map { max(0, noteDate.timeIntervalSince($0)) }
    }

    /// Loop only takes the passwords of the last few periods; a push that arrives later fails this way.
    var passwordExpired: Bool {
        error.contains("has expired")
    }

    var title: String {
        String(format: String(localized: "⚠️ Rejected by Loop: %@", table: "RemoteCommandRejection", comment: "Notification title when Loop rejected a remote command (1: the command, e.g. a bolus of 0.5 U)"), command)
    }

    var body: String {
        if passwordExpired, let delay, delay >= 30 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = delay >= 60 ? [.minute, .second] : [.second]
            formatter.unitsStyle = .short
            let late = formatter.string(from: delay) ?? "\(Int(delay)) s"
            return String(format: String(localized: "Nothing was given. The command took %@ to reach Loop's phone, so Loop rejected its password as expired. Check the graph before sending again.", table: "RemoteCommandRejection", comment: "Notification body when a remote command arrived too late (1: how long it took, e.g. 2 min 22 s)"), late)
        }
        return String(format: String(localized: "Nothing was given. Loop said: %@", table: "RemoteCommandRejection", comment: "Notification body when Loop rejected a remote command (1: Loop's error)"), error)
    }
}

/// Watches Nightscout's notes for commands from here that Loop rejected, and says so.
final class RemoteCommandRejectionMonitor {
    static let shared = RemoteCommandRejectionMonitor()

    /// Loop drops a command 5 minutes after it was sent; its note can trail by a refresh.
    static let watchWindow: TimeInterval = 8 * 60
    /// Older notes are history (the first refresh after an install), not news.
    static let maxNoteAge: TimeInterval = 30 * 60

    private(set) var watchUntil: Date?

    /// Called once Apple has taken a command: look at Nightscout every minute until Loop has had its say.
    func commandSent(now: Date = Date()) {
        watchUntil = now.addingTimeInterval(Self.watchWindow)
        TaskScheduler.shared.rescheduleTask(id: .treatments, to: now.addingTimeInterval(60))
    }

    func isWatching(now: Date = Date()) -> Bool {
        guard let watchUntil else { return false }
        return now < watchUntil
    }

    /// The rejections not yet told, oldest first.
    static func newRejections(in notes: [[String: AnyObject]], since lastNotified: Date?, now: Date) -> [RemoteCommandRejection] {
        notes.compactMap(RemoteCommandRejection.init(treatment:))
            .filter { $0.noteDate > (lastNotified ?? .distantPast) && now.timeIntervalSince($0.noteDate) < maxNoteAge }
            .sorted { $0.noteDate < $1.noteDate }
    }

    func check(notes: [[String: AnyObject]], now: Date = Date()) {
        let rejections = Self.newRejections(in: notes, since: Storage.shared.lastRemoteRejectionNotified.value, now: now)
        guard let newest = rejections.last else { return }
        Storage.shared.lastRemoteRejectionNotified.value = newest.noteDate

        for rejection in rejections {
            LogManager.shared.log(category: .apns, message: "Loop rejected \(rejection.command): \(rejection.error) (delay \(rejection.delay.map { "\(Int($0)) s" } ?? "unknown"))")

            let content = UNMutableNotificationContent()
            content.title = rejection.title
            content.body = rejection.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(identifier: "remoteCommandRejected-\(rejection.noteDate.timeIntervalSince1970)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
