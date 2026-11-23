// LoopFollow
// DoseGuard.swift

import Foundation

/// A dose given by hand, as Loop's own log tells it.
struct LoggedDose: Codable, Equatable {
    enum Source: String, Codable {
        /// The bolus screen of the phone with Loop.
        case phone
        /// A remote command: from here, or from someone else's LoopFollow.
        case remote
        case eveningWatch
    }

    /// When Loop was asked for it, just before it went to the pump.
    let date: Date
    let units: Double
    let source: Source

    init(date: Date, units: Double, source: Source) {
        self.date = date
        self.units = units
        self.source = source
    }

    /// One entry of `doses` in Loop's "Manual Dose Log", or of a stopped command's `statusDetails`.
    init?(document: [String: Any]) {
        guard let dateString = document["date"] as? String,
              let date = NightscoutUtils.parseDate(dateString),
              let units = (document["units"] as? NSNumber)?.doubleValue, units > 0
        else { return nil }
        self.date = date
        self.units = units
        // A source this version does not know is still a dose from somewhere else.
        source = (document["source"] as? String).flatMap(Source.init(rawValue:)) ?? .phone
    }
}

/// Keeps two people from correcting the same glucose at the same moment without knowing of each other.
///
/// Someone with the child can bolus on the phone with Loop while a caregiver sends a bolus from here.
/// On 20 November 2026 0.30 U and 0.50 U were given two minutes apart at 17.2 mmol/L, and glucose was
/// 2.9 three hours later.
///
/// Loop (the jujasen fork, `ManualDoseLog`) is the referee. It logs who gave each dose by hand and
/// uploads the log as a "Manual Dose Log" treatment (`source: "manualDoseLog"`, `doses` with `date`,
/// `units`, `source`, `delivered`). Every bolus sent from here carries `known-doses-until`: the user
/// has seen every dose up to that time. If Loop has a later one, it gives nothing and answers with
/// `statusDetails` (`reason: "unknownDoses"`, `doses`), and the card here says which dose was missed.
///
/// A dose counts as seen once the bolus screen has warned about it and the user chose to send anyway.
/// A bolus sent without that (from the watch, or in the seconds before the log arrives here) therefore
/// claims to know nothing of it, and Loop stops it. A plain «a bolus was given recently» would not do:
/// meals are often entered as several boluses minutes apart, all by the same person.
final class DoseGuard: ObservableObject {
    static let shared = DoseGuard()

    static let logEventType = "Manual Dose Log"
    static let stoppedReason = "unknownDoses"
    static let keyInPayload = "known-doses-until"

    /// A dose from somewhere else calls for a warning this long. The corrections two people gave at
    /// once came within a quarter of an hour of each other.
    static let warnsFor: TimeInterval = 30 * 60
    /// With nothing known, a bolus claims to have seen the doses up to this long ago. Loop only
    /// checks the last three hours.
    static let lookBack: TimeInterval = 24 * 60 * 60
    /// How far short of a dose the user has not been warned about the claim stops. Loop takes a
    /// time within half a second of a dose as knowing of it (times travel in milliseconds).
    static let shortOfUnseen: TimeInterval = 1

    /// Loop's log as last downloaded, oldest first.
    @Published private(set) var logged: [LoggedDose] = []
    /// The user has been warned about every dose up to here and chose to send anyway.
    @Published private(set) var acknowledgedUntil: Date?

    private let defaults: UserDefaults
    private static let acknowledgedKey = "doseGuard.acknowledgedUntil"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.acknowledgedKey)
        acknowledgedUntil = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    // MARK: From Nightscout

    /// The doses of the newest log among the treatments; nil when there is none.
    static func doses(inLogs logs: [[String: AnyObject]]) -> [LoggedDose]? {
        let newest = logs
            .compactMap { log -> (Date, [String: AnyObject])? in
                guard let date = NightscoutUtils.treatmentDate(from: log) else { return nil }
                return (date, log)
            }
            .max { $0.0 < $1.0 }
        guard let documents = newest?.1["doses"] as? [[String: Any]] else { return nil }
        return documents.compactMap(LoggedDose.init(document:)).sorted { $0.date < $1.date }
    }

    /// Called with every treatment download.
    func update(logs: [[String: AnyObject]]) {
        guard let doses = Self.doses(inLogs: logs), doses != logged else { return }
        logged = doses
    }

    // MARK: Whose dose is it?

    /// A remote dose in Loop's log that a command sent from here accounts for.
    static func isOwn(_ dose: LoggedDose, commands: [QueuedRemoteCommand]) -> Bool {
        guard dose.source == .remote else { return false }
        return commands.contains { command in
            guard let units = command.units, abs(units - dose.units) < 0.026 else { return false }
            switch command.status {
            case .rejected, .cancelled, .failed:
                return false
            default:
                break
            }
            let latest = (command.handledAt ?? command.expiration).addingTimeInterval(2 * 60)
            return dose.date >= command.sentAt.addingTimeInterval(-2 * 60) && dose.date <= latest
        }
    }

    /// The doses someone else gave in the last half hour, oldest first: on the phone with Loop, by the
    /// evening watch, from another LoopFollow, and the ones Loop named when it stopped a bolus from here.
    static func fromElsewhere(logged: [LoggedDose], commands: [QueuedRemoteCommand], now: Date) -> [LoggedDose] {
        let stopped = commands.flatMap { $0.stoppedBy ?? [] }
        var result: [LoggedDose] = []
        for dose in (logged.filter { !isOwn($0, commands: commands) } + stopped).sorted(by: { $0.date < $1.date }) {
            guard now.timeIntervalSince(dose.date) <= warnsFor, dose.date <= now.addingTimeInterval(60) else { continue }
            // The same dose can be in the log and in a stopped command's answer.
            if result.contains(where: { abs($0.date.timeIntervalSince(dose.date)) < 1 && abs($0.units - dose.units) < 0.001 }) { continue }
            result.append(dose)
        }
        return result
    }

    func fromElsewhere(commands: [QueuedRemoteCommand] = RemoteCommandInbox.shared.commands, now: Date = Date()) -> [LoggedDose] {
        Self.fromElsewhere(logged: logged, commands: commands, now: now)
    }

    /// The ones the user has not been warned about yet.
    func unacknowledged(commands: [QueuedRemoteCommand] = RemoteCommandInbox.shared.commands, now: Date = Date()) -> [LoggedDose] {
        fromElsewhere(commands: commands, now: now).filter { $0.date > (acknowledgedUntil ?? .distantPast) }
    }

    /// The user saw the warning about these doses and chose to send anyway.
    func acknowledge(_ doses: [LoggedDose]) {
        guard let newest = doses.map(\.date).max(), newest > (acknowledgedUntil ?? .distantPast) else { return }
        acknowledgedUntil = newest
        defaults.set(newest.timeIntervalSince1970, forKey: Self.acknowledgedKey)
    }

    // MARK: What a bolus from here claims to know

    /// The time a bolus sent now carries as `known-doses-until`.
    ///
    /// Everything in Loop's log, the boluses from here that Loop has confirmed and what the user has
    /// acknowledged count as seen, but never a dose from somewhere else the user has not been warned
    /// about: the time stops a second short of the oldest of those, so Loop stops the bolus.
    static func knownDosesUntil(logged: [LoggedDose], commands: [QueuedRemoteCommand], acknowledgedUntil: Date?, now: Date) -> Date {
        let ahead = now.addingTimeInterval(60)
        var known = now.addingTimeInterval(-lookBack)
        for date in logged.map(\.date) + commands.filter({ $0.status == .done }).compactMap(\.handledAt) + [acknowledgedUntil].compactMap({ $0 }) where date <= ahead {
            known = max(known, date)
        }
        let unseen = fromElsewhere(logged: logged, commands: commands, now: now).filter { $0.date > (acknowledgedUntil ?? .distantPast) }
        if let oldest = unseen.map(\.date).min() {
            known = min(known, oldest.addingTimeInterval(-shortOfUnseen))
        }
        return known
    }

    func knownDosesUntil(commands: [QueuedRemoteCommand] = RemoteCommandInbox.shared.commands, now: Date = Date()) -> Date {
        Self.knownDosesUntil(logged: logged, commands: commands, acknowledgedUntil: acknowledgedUntil, now: now)
    }
}

/// Every sentence about a dose someone else gave, in one place.
enum DoseGuardText {
    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func units(_ value: Double) -> String {
        Localizer.formatToLocalizedString(value, maxFractionDigits: 2, minFractionDigits: 0)
    }

    /// «0.5 U was given on the phone with Loop at 22:17.»
    static func sentence(_ dose: LoggedDose) -> String {
        switch dose.source {
        case .phone:
            return String(format: String(localized: "%1$@ U was given on the phone with Loop at %2$@.", table: "RemoteCommandInbox", comment: "A dose someone gave on the phone with Loop (1: units, 2: time)"), units(dose.units), time(dose.date))
        case .eveningWatch:
            return String(format: String(localized: "The evening watch gave %1$@ U at %2$@.", table: "RemoteCommandInbox", comment: "A dose Loop's evening watch gave (1: units, 2: time)"), units(dose.units), time(dose.date))
        case .remote:
            return String(format: String(localized: "%1$@ U was given as a remote bolus from another phone at %2$@.", table: "RemoteCommandInbox", comment: "A remote bolus that was not sent from this phone (1: units, 2: time)"), units(dose.units), time(dose.date))
        }
    }

    static func sentences(_ doses: [LoggedDose]) -> String {
        doses.map(sentence).joined(separator: "\n")
    }

    static func minutesAgo(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 {
            return String(localized: "just now", table: "RemoteCommandInbox", comment: "How long ago a dose was given, when under a minute")
        }
        return String(format: String(localized: "%d min ago", table: "RemoteCommandInbox", comment: "How long ago a dose was given (1: minutes)"), minutes)
    }

    static var sectionTitle: String {
        String(localized: "Given by someone else", table: "RemoteCommandInbox", comment: "Header over the doses someone else gave in the last half hour, on the bolus screen")
    }

    static var sectionFooter: String {
        String(localized: "Someone else may be correcting the same glucose. Check the insulin on board before you send more.", table: "RemoteCommandInbox")
    }

    static var alertTitle: String {
        String(localized: "A dose was just given by someone else", table: "RemoteCommandInbox")
    }

    static func alertMessage(_ doses: [LoggedDose], sending newUnits: Double) -> String {
        String(format: String(localized: "%1$@\n\nIf you send %2$@ U now, it comes on top of that. Send it anyway?", table: "RemoteCommandInbox", comment: "1: the doses someone else gave, one per line, 2: the new amount"), sentences(doses), units(newUnits))
    }

    /// For the card of a bolus Loop stopped.
    static func stoppedDetail(_ doses: [LoggedDose]) -> String {
        String(format: String(localized: "%@\nLoopFollow had not shown you that when you sent, so Loop gave nothing. Look at the graph and the insulin on board before you send again.", table: "RemoteCommandInbox", comment: "1: the doses someone else gave, one per line"), sentences(doses))
    }
}
