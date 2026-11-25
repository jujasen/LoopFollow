// LoopFollow
// RemoteCommandInbox.swift

import CryptoKit
import Foundation
import UserNotifications

/// LoopFollow's side of Loop's remote command inbox.
///
/// A push only reaches Loop when iOS lets it, and iOS often holds it until someone opens Loop on
/// the other phone. Loop (the jujasen fork, NightscoutService `RemoteCommandInbox`) therefore also
/// fetches commands from Nightscout on every run, every five minutes, carries each out at most once
/// and writes the outcome back into the same treatment. LoopFollow puts the command there, sends a
/// push that only tells Loop to look now, and follows the treatment until Loop has answered.
///
/// The treatment: `eventType` "Remote Command", `commandId`, `payload` (the push's keys as a JSON
/// string, with `command-id`), `signature` (base64 HMAC-SHA256 of the payload, keyed with the UTF-8
/// bytes of the `secret` in Loop's QR code), `status` (`pending` → `running` → `done`, `failed`,
/// `uncertain` or `rejected`), `statusMessage`, `handledAt`. The password (`otp`) and the return
/// address are left out: anyone who can read Nightscout could use them.
struct QueuedRemoteCommand: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        /// In Nightscout, not yet fetched.
        case pending
        /// Loop has taken it on.
        case running
        case done
        case failed
        /// The pump may or may not have delivered.
        case uncertain
        case rejected
        /// Withdrawn from here before Loop fetched it.
        case cancelled
        /// Sent only as a push (a Loop without the inbox): nothing will come back.
        case pushOnly
    }

    let commandId: String
    var objectId: String?
    /// "Bolus 0,5 E", "Karbo 20 g", …
    let summary: String
    let units: Double?
    let sentAt: Date
    let expiration: Date
    var status: Status
    var statusMessage: String?
    var handledAt: Date?
    var dismissed: Bool = false
    /// The bolus turned up in Nightscout at this time, whatever Loop said (or could not say) about it.
    var seenInNightscout: Date?
    /// Loop gave nothing because of these doses, which someone else gave and this bolus did not
    /// claim to know of (`DoseGuard`).
    var stoppedBy: [LoggedDose]?
    /// A meal with bolus (`MealBolusCommand`): what was sent and what Loop said became of it.
    /// `units` is then the most Loop may give.
    var meal: MealBolusDetails?
    /// When Loop was first seen to have taken it.
    var receivedAt: Date?

    var id: String { commandId }
    var isBolus: Bool { units != nil }

    /// A bolus of this size could be the one this command gave. A meal bolus can be smaller than
    /// approved: Loop gives the smaller of its own recommendation and the approved amount.
    func couldHaveGiven(units bolus: Double) -> Bool {
        guard let units else { return false }
        // Pumps round to 0.05 U (some to 0.025).
        if let meal {
            if let delivered = meal.deliveredUnits {
                return delivered > 0 && abs(delivered - bolus) < 0.026
            }
            return bolus > 0 && bolus < units + 0.026
        }
        return abs(units - bolus) < 0.026
    }

    /// The carbs are in Loop: sending the meal again would count them twice.
    var carbsSaved: Bool {
        meal?.carbsSaved == true || (meal != nil && status == .done)
    }

    /// How long after sending a bolus from here may still turn up in Nightscout: Loop takes a late push
    /// for up to five minutes and uploads on its next run.
    static let deliveryWindow: TimeInterval = 20 * 60

    /// A bolus in Nightscout could be this one: no answer from Loop says otherwise yet.
    var canBeMatchedToNightscout: Bool {
        guard isBolus, seenInNightscout == nil else { return false }
        switch status {
        case .pushOnly, .pending, .running, .uncertain: return true
        default: return false
        }
    }

    /// The decoder tolerates commands saved before `dismissed` and `seenInNightscout` existed.
    enum CodingKeys: String, CodingKey {
        case commandId, objectId, summary, units, sentAt, expiration, status, statusMessage, handledAt, dismissed, seenInNightscout, stoppedBy, meal, receivedAt
    }

    init(commandId: String, objectId: String?, summary: String, units: Double?, sentAt: Date, expiration: Date, status: Status, statusMessage: String? = nil, handledAt: Date? = nil, dismissed: Bool = false, seenInNightscout: Date? = nil, stoppedBy: [LoggedDose]? = nil, meal: MealBolusDetails? = nil) {
        self.commandId = commandId
        self.objectId = objectId
        self.summary = summary
        self.units = units
        self.sentAt = sentAt
        self.expiration = expiration
        self.status = status
        self.statusMessage = statusMessage
        self.handledAt = handledAt
        self.dismissed = dismissed
        self.seenInNightscout = seenInNightscout
        self.stoppedBy = stoppedBy
        self.meal = meal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(String.self, forKey: .commandId)
        objectId = try c.decodeIfPresent(String.self, forKey: .objectId)
        summary = try c.decode(String.self, forKey: .summary)
        units = try c.decodeIfPresent(Double.self, forKey: .units)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        expiration = try c.decode(Date.self, forKey: .expiration)
        status = try c.decode(Status.self, forKey: .status)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        handledAt = try c.decodeIfPresent(Date.self, forKey: .handledAt)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        seenInNightscout = try c.decodeIfPresent(Date.self, forKey: .seenInNightscout)
        stoppedBy = try c.decodeIfPresent([LoggedDose].self, forKey: .stoppedBy)
        meal = try c.decodeIfPresent(MealBolusDetails.self, forKey: .meal)
        receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt)
    }

    /// Loop's clock and ours may differ a little; wait this long past expiration before calling it lapsed.
    static let clockMargin: TimeInterval = 60
    /// Loop says it started but never said how it went.
    static let silentAfterStart: TimeInterval = 3 * 60

    enum Phase: Equatable {
        case waiting
        case giving
        case given
        case failed
        case uncertain
        case rejected
        /// Loop gave nothing: someone else had given a dose this bolus did not know of.
        case stopped
        case cancelled
        /// Loop never fetched it, and now never will.
        case lapsed
        /// Loop started and then went quiet.
        case noAnswer
        case pushWaiting
        case pushLapsed
        /// A meal with bolus: Loop saved the carbs and worked out that no bolus was needed.
        case savedWithoutBolus
        /// A meal with bolus: Loop saved the carbs, but the bolus was not given.
        case carbsSavedBolusFailed
    }

    func phase(now: Date) -> Phase {
        if seenInNightscout != nil { return .given }
        if let meal {
            switch status {
            case .done where meal.deliveredUnits == 0:
                return .savedWithoutBolus
            case .failed, .rejected:
                if meal.carbsSaved == true { return .carbsSavedBolusFailed }
            default:
                break
            }
        }
        switch status {
        case .pending:
            return now > expiration.addingTimeInterval(Self.clockMargin) ? .lapsed : .waiting
        case .running:
            let started = handledAt ?? sentAt
            return now > started.addingTimeInterval(Self.silentAfterStart) ? .noAnswer : .giving
        case .done: return .given
        case .failed: return .failed
        case .uncertain: return .uncertain
        case .rejected: return stoppedBy?.isEmpty == false ? .stopped : .rejected
        case .cancelled: return .cancelled
        case .pushOnly:
            return now > expiration.addingTimeInterval(Self.clockMargin) ? .pushLapsed : .pushWaiting
        }
    }

    /// Could still lead to insulin: a second bolus now could be given on top of it.
    func mayStillDeliver(now: Date) -> Bool {
        switch phase(now: now) {
        case .waiting, .giving, .pushWaiting:
            return true
        case .noAnswer, .uncertain:
            // Unknown: treat as possibly given for a while.
            return now < sentAt.addingTimeInterval(60 * 60)
        default:
            return false
        }
    }

    /// Still worth looking in Nightscout for an answer.
    func awaitsAnswer(now: Date) -> Bool {
        switch phase(now: now) {
        case .waiting, .giving, .noAnswer:
            return now < sentAt.addingTimeInterval(60 * 60)
        case .lapsed:
            // One last look, so the lapse is told (and a late answer still counts).
            return now < expiration.addingTimeInterval(Self.clockMargin + 5 * 60)
        case .cancelled:
            // Loop may have taken it just before it was withdrawn.
            return now < expiration.addingTimeInterval(Self.clockMargin)
        default:
            return false
        }
    }

    /// Shown on the main screen.
    func isVisible(now: Date) -> Bool {
        guard !dismissed else { return false }
        switch phase(now: now) {
        case .given, .cancelled, .savedWithoutBolus:
            return now < (handledAt ?? sentAt).addingTimeInterval(20 * 60)
        default:
            return now < sentAt.addingTimeInterval(3 * 60 * 60)
        }
    }

    mutating func apply(treatment: [String: Any], now: Date = Date()) {
        if let objectId = treatment["_id"] as? String {
            self.objectId = objectId
        }
        if let raw = treatment["status"] as? String, let status = Status(rawValue: raw) {
            // Our own withdrawal stays unless Loop got there first.
            if !(self.status == .cancelled && status == .pending) {
                self.status = status
            }
        }
        if let message = treatment["statusMessage"] as? String {
            statusMessage = message
        }
        if let handled = treatment["handledAt"] as? String, let date = NightscoutUtils.parseDate(handled) {
            handledAt = date
        }
        if receivedAt == nil, status != .pending, status != .cancelled, status != .pushOnly {
            receivedAt = handledAt ?? now
        }
        if meal != nil, let details = treatment["statusDetails"] as? [String: Any] {
            meal?.apply(statusDetails: details)
        }
        if let details = treatment["statusDetails"] as? [String: Any],
           details["reason"] as? String == DoseGuard.stoppedReason,
           let doses = details["doses"] as? [[String: Any]]
        {
            let stopped = doses.compactMap(LoggedDose.init(document:)).sorted { $0.date < $1.date }
            stoppedBy = stopped.isEmpty ? nil : stopped
        }
    }
}

final class RemoteCommandInbox: ObservableObject {
    static let shared = RemoteCommandInbox()

    static let eventType = "Remote Command"
    /// How long Loop may take: it fetches every five minutes, so one run can be late or skipped.
    static let lifetime: TimeInterval = 10 * 60
    static let pollInterval: TimeInterval = 15

    @Published private(set) var commands: [QueuedRemoteCommand]

    private let defaults: UserDefaults
    private static let storageKey = "remoteCommandInbox.commands"
    private var timer: Timer?
    private var isFetching = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let commands = try? JSONDecoder().decode([QueuedRemoteCommand].self, from: data)
        {
            self.commands = commands
        } else {
            commands = []
        }
        DispatchQueue.main.async { self.scheduleFetching() }
    }

    // MARK: Can it be used?

    /// Loop says it fetches commands from Nightscout, LoopFollow may write there, and the QR code is known.
    var isAvailable: Bool {
        Storage.shared.loopRemoteCommandInbox.value >= 1
            && Storage.shared.nsWriteAuth.value
            && Self.secret(fromQRCodeURL: Storage.shared.loopAPNSQrCodeURL.value) != nil
    }

    /// Why commands go the way they do, for the settings screen.
    static var availabilityText: String {
        if Storage.shared.loopRemoteCommandInbox.value < 1 {
            return String(localized: "Push only: this Loop does not fetch commands from Nightscout yet. A command then only arrives when iOS delivers the push, which can wait until Loop is opened.", table: "RemoteCommandInbox")
        }
        if !Storage.shared.nsWriteAuth.value {
            return String(localized: "Push only: the Nightscout token can't write. Use a token with the careportal role so commands can wait in Nightscout until Loop fetches them.", table: "RemoteCommandInbox")
        }
        if secret(fromQRCodeURL: Storage.shared.loopAPNSQrCodeURL.value) == nil {
            return String(localized: "Push only: scan Loop's QR code again.", table: "RemoteCommandInbox")
        }
        return String(localized: "Through Nightscout: Loop fetches commands on every run (every 5 minutes) and right away when the push gets through, and says what became of each.", table: "RemoteCommandInbox")
    }

    static func secret(fromQRCodeURL urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value,
              !secret.isEmpty
        else { return nil }
        return secret
    }

    // MARK: Sending

    enum InboxError: LocalizedError {
        case notAvailable
        case nightscoutRefused(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return String(localized: "Remote commands through Nightscout are not set up.", table: "RemoteCommandInbox")
            case .nightscoutRefused(let reason):
                return String(format: String(localized: "Nightscout did not take the command: %@", table: "RemoteCommandInbox", comment: "1: Nightscout's answer"), reason)
            }
        }
    }

    /// The payload Loop gets: the push's own keys, a command id and a longer life, without the password.
    static func inboxPayload(from pushPayload: [String: Any], commandId: String, sentAt: Date) -> [String: Any] {
        var payload = pushPayload
        payload.removeValue(forKey: "otp")
        payload.removeValue(forKey: "encrypted_return_notification")
        payload.removeValue(forKey: "return_notification")
        payload["command-id"] = commandId
        payload["sent-at"] = format(sentAt)
        payload["expiration"] = format(sentAt.addingTimeInterval(lifetime))
        return payload
    }

    static func sign(payload: String, secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(code).base64EncodedString()
    }

    static func treatment(payload: [String: Any], commandId: String, summary: String, secret: String, sentAt: Date) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return [
            "eventType": eventType,
            "created_at": format(sentAt),
            "enteredBy": "LoopFollow",
            "notes": summary,
            "commandId": commandId,
            "payload": json,
            "signature": sign(payload: json, secret: secret),
            "status": QueuedRemoteCommand.Status.pending.rawValue,
        ]
    }

    /// Puts the command in Nightscout. Loop carries it out on its next run, or at once if the push gets through.
    func enqueue(pushPayload: [String: Any], summary: String, units: Double?, meal: MealBolusDetails? = nil, now: Date = Date()) async throws -> QueuedRemoteCommand {
        guard isAvailable, let secret = Self.secret(fromQRCodeURL: Storage.shared.loopAPNSQrCodeURL.value) else {
            throw InboxError.notAvailable
        }
        let commandId = UUID().uuidString
        let payload = Self.inboxPayload(from: pushPayload, commandId: commandId, sentAt: now)
        let body = try Self.treatment(payload: payload, commandId: commandId, summary: summary, secret: secret, sentAt: now)

        let objectId = try await Self.post(body)
        let command = QueuedRemoteCommand(
            commandId: commandId,
            objectId: objectId,
            summary: summary,
            units: units,
            sentAt: now,
            expiration: now.addingTimeInterval(Self.lifetime),
            status: .pending,
            meal: meal
        )
        await MainActor.run {
            self.add(command)
        }
        LogManager.shared.log(category: .apns, message: "Remote command \(summary) queued in Nightscout (\(commandId))")
        return command
    }

    /// For a Loop without the inbox: remembered so a second bolus is not sent blindly.
    func recordPushOnly(summary: String, units: Double?, sentAt: Date = Date(), expiration: Date) {
        let command = QueuedRemoteCommand(
            commandId: UUID().uuidString,
            objectId: nil,
            summary: summary,
            units: units,
            sentAt: sentAt,
            expiration: expiration,
            status: .pushOnly
        )
        DispatchQueue.main.async { self.add(command) }
    }

    /// Withdraws a command Loop has not fetched yet. If Loop got there first, its answer wins.
    func cancel(_ command: QueuedRemoteCommand) {
        guard command.status == .pending, let objectId = command.objectId else { return }
        update(command.commandId) { $0.status = .cancelled; $0.handledAt = Date() }
        Task {
            do {
                // Only if it is still waiting: Loop's own claim must not be overwritten.
                let current = try await Self.fetch(objectIds: [objectId]).first
                guard var treatment = current, treatment["status"] as? String == QueuedRemoteCommand.Status.pending.rawValue else {
                    await MainActor.run { self.fetchNow() }
                    return
                }
                treatment["status"] = QueuedRemoteCommand.Status.cancelled.rawValue
                treatment["statusMessage"] = String(localized: "Withdrawn in LoopFollow", table: "RemoteCommandInbox")
                try await Self.put(treatment)
            } catch {
                LogManager.shared.log(category: .apns, message: "Could not withdraw remote command: \(error.localizedDescription)")
            }
            await MainActor.run { self.fetchNow() }
        }
    }

    func dismiss(_ command: QueuedRemoteCommand) {
        update(command.commandId) { $0.dismissed = true }
    }

    // MARK: State

    /// The newest bolus that could still be given.
    func openBolus(now: Date = Date()) -> QueuedRemoteCommand? {
        commands.filter { $0.isBolus && $0.mayStillDeliver(now: now) }.max { $0.sentAt < $1.sentAt }
    }

    func visible(now: Date = Date()) -> [QueuedRemoteCommand] {
        commands.filter { $0.isVisible(now: now) }.sorted { $0.sentAt > $1.sentAt }
    }

    private func add(_ command: QueuedRemoteCommand) {
        let now = Date()
        commands = (commands.filter { now.timeIntervalSince($0.sentAt) < 24 * 60 * 60 } + [command])
        save()
        scheduleFetching()
    }

    private func update(_ commandId: String, _ change: (inout QueuedRemoteCommand) -> Void) {
        guard let index = commands.firstIndex(where: { $0.commandId == commandId }) else { return }
        change(&commands[index])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commands) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Following up

    private func scheduleFetching() {
        let waiting = commands.contains { $0.awaitsAnswer(now: Date()) }
        if waiting, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.fetchNow()
            }
            fetchNow()
        } else if !waiting {
            timer?.invalidate()
            timer = nil
        }
    }

    func fetchNow() {
        let now = Date()
        let open = commands.filter { $0.awaitsAnswer(now: now) && $0.objectId != nil }
        guard !open.isEmpty, !isFetching else {
            scheduleFetching()
            return
        }
        isFetching = true
        Task {
            let treatments = try? await Self.fetch(objectIds: open.compactMap(\.objectId))
            await MainActor.run {
                self.isFetching = false
                if let treatments {
                    self.merge(treatments, now: Date())
                }
                self.scheduleFetching()
            }
        }
    }

    /// Applies Loop's answers and tells about the ones that just came in.
    func merge(_ treatments: [[String: Any]], now: Date) {
        var changed = false
        for treatment in treatments {
            guard let commandId = treatment["commandId"] as? String,
                  let index = commands.firstIndex(where: { $0.commandId == commandId })
            else { continue }
            let before = commands[index]
            commands[index].apply(treatment: treatment, now: now)
            if commands[index] != before {
                changed = true
                if before.phase(now: now) != commands[index].phase(now: now) {
                    RemoteCommandInboxNotifier.announce(commands[index], now: now)
                }
            }
        }
        // Lapsed without an answer: say so once.
        for index in commands.indices where commands[index].status == .pending && commands[index].phase(now: now) == .lapsed {
            if !defaults.bool(forKey: "remoteCommandInbox.lapsed.\(commands[index].commandId)") {
                defaults.set(true, forKey: "remoteCommandInbox.lapsed.\(commands[index].commandId)")
                RemoteCommandInboxNotifier.announce(commands[index], now: now)
            }
        }
        if changed { save() }
    }

    // MARK: Boluses seen in Nightscout

    /// Pairs boluses from Nightscout with the commands sent from here, oldest first, each bolus used once.
    /// Without this a bolus sent only as a push (a Loop that can't answer) was called «can no longer be
    /// given» once its time ran out, even when it had been given long before.
    static func matches(commands: [QueuedRemoteCommand], boluses: [(date: Date, units: Double)]) -> [String: Date] {
        var used = Set<Int>()
        var result: [String: Date] = [:]
        for command in commands.filter(\.canBeMatchedToNightscout).sorted(by: { $0.sentAt < $1.sentAt }) {
            guard command.units != nil else { continue }
            let from = command.sentAt.addingTimeInterval(-QueuedRemoteCommand.clockMargin)
            let to = command.sentAt.addingTimeInterval(QueuedRemoteCommand.deliveryWindow)
            let candidate = boluses.indices
                .filter { !used.contains($0) }
                .filter { boluses[$0].date >= from && boluses[$0].date <= to }
                .filter { command.couldHaveGiven(units: boluses[$0].units) }
                .min { boluses[$0].date < boluses[$1].date }
            if let candidate {
                used.insert(candidate)
                result[command.commandId] = boluses[candidate].date
            }
        }
        return result
    }

    /// Commands that may still turn up as a bolus in Nightscout: look there every minute.
    func watchesTreatments(now: Date = Date()) -> Bool {
        commands.contains { $0.canBeMatchedToNightscout && now < $0.sentAt.addingTimeInterval(QueuedRemoteCommand.deliveryWindow + 5 * 60) }
    }

    /// Called with every treatment download: a bolus that matches a command means it was given.
    func noteBoluses(_ entries: [[String: AnyObject]], now: Date = Date()) {
        let boluses: [(date: Date, units: Double)] = entries.compactMap { entry in
            guard let date = NightscoutUtils.treatmentDate(from: entry), let units = entry["insulin"] as? Double, units > 0 else { return nil }
            return (date, units)
        }
        let found = Self.matches(commands: commands, boluses: boluses)
        guard !found.isEmpty else { return }
        for (commandId, date) in found {
            update(commandId) { $0.seenInNightscout = date }
            if let command = commands.first(where: { $0.commandId == commandId }) {
                LogManager.shared.log(category: .apns, message: "Remote command \(command.summary) seen in Nightscout at \(date)")
                RemoteCommandInboxNotifier.announce(command, now: now)
            }
        }
    }

    // MARK: Nightscout

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func url(_ endpoint: String, _ parameters: [String: String] = [:]) throws -> URL {
        guard let url = NightscoutUtils.constructURL(baseURL: Storage.shared.url.value, token: Storage.shared.token.value, endpoint: endpoint, parameters: parameters) else {
            throw NightscoutUtils.NightscoutError.invalidURL
        }
        return url
    }

    private static func post(_ body: [String: Any]) async throws -> String? {
        var request = URLRequest(url: try url("/api/v1/treatments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            throw InboxError.nightscoutRefused("HTTP \(code) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let created = try? JSONSerialization.jsonObject(with: data)
        if let list = created as? [[String: Any]] {
            return list.first?["_id"] as? String
        }
        return (created as? [String: Any])?["_id"] as? String
    }

    private static func put(_ treatment: [String: Any]) async throws {
        var request = URLRequest(url: try url("/api/v1/treatments"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: treatment)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw InboxError.nightscoutRefused("HTTP \(code)") }
    }

    private static func fetch(objectIds: [String]) async throws -> [[String: Any]] {
        var parameters = [
            "find[eventType]": eventType,
            "count": "\(max(objectIds.count, 1) * 2)",
        ]
        if objectIds.count == 1 {
            parameters["find[_id]"] = objectIds[0]
        } else {
            parameters["find[created_at][$gte]"] = format(Date().addingTimeInterval(-2 * 60 * 60))
            parameters["count"] = "50"
        }
        var request = URLRequest(url: try url("/api/v1/treatments.json", parameters))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let treatments = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return treatments.filter { objectIds.contains($0["_id"] as? String ?? "") }
    }
}

/// The confirmation that never came before: a notification when Loop has answered.
enum RemoteCommandInboxNotifier {
    static func announce(_ command: QueuedRemoteCommand, now: Date) {
        guard let text = RemoteCommandText.notification(command, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "remoteCommand-\(command.commandId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Every sentence about a remote command, in one place.
enum RemoteCommandText {
    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func title(_ command: QueuedRemoteCommand, now: Date) -> String {
        let s = command.summary
        switch command.phase(now: now) {
        case .given where command.meal?.deliveredUnits != nil:
            // What Loop gave, which can be less than approved.
            let meal = command.meal!
            return String(format: String(localized: "✅ %@ given at %@", table: "RemoteCommandInbox", comment: "1: command, 2: time"), summary(mealCarbs: meal.carbs, units: meal.deliveredUnits ?? meal.approvedUnits), time(command.seenInNightscout ?? command.handledAt ?? now))
        case .savedWithoutBolus:
            return String(format: String(localized: "✅ Carbs %@ g saved, no bolus", table: "RemoteCommandInbox", comment: "1: grams"), grams(command.meal?.carbs ?? 0))
        case .carbsSavedBolusFailed:
            return String(localized: "⚠️ Carbs saved, bolus not given", table: "RemoteCommandInbox")
        case .waiting:
            return String(format: String(localized: "⏳ %@: waiting for Loop", table: "RemoteCommandInbox", comment: "1: e.g. Bolus 0.5 U"), s)
        case .giving:
            return String(format: String(localized: "💉 %@: Loop is giving it", table: "RemoteCommandInbox"), s)
        case .given:
            return String(format: String(localized: "✅ %@ given at %@", table: "RemoteCommandInbox", comment: "1: command, 2: time"), s, time(command.seenInNightscout ?? command.handledAt ?? now))
        case .failed:
            return String(format: String(localized: "❌ %@ not given", table: "RemoteCommandInbox"), s)
        case .rejected:
            return String(format: String(localized: "❌ %@ rejected by Loop", table: "RemoteCommandInbox"), s)
        case .stopped:
            return String(format: String(localized: "🛑 %@ stopped: someone else had just given a dose", table: "RemoteCommandInbox", comment: "1: e.g. Bolus 0.5 U"), s)
        case .uncertain:
            return String(format: String(localized: "⚠️ %@: unsure whether it was given", table: "RemoteCommandInbox"), s)
        case .cancelled:
            return String(format: String(localized: "%@ withdrawn", table: "RemoteCommandInbox"), s)
        case .lapsed:
            return String(format: String(localized: "⌛ %@ never reached Loop", table: "RemoteCommandInbox"), s)
        case .noAnswer:
            return String(format: String(localized: "⚠️ %@: Loop started but has not answered", table: "RemoteCommandInbox"), s)
        case .pushWaiting:
            return String(format: String(localized: "⏳ %@ sent as a push", table: "RemoteCommandInbox"), s)
        case .pushLapsed:
            return String(format: String(localized: "%@: no bolus in Nightscout", table: "RemoteCommandInbox", comment: "1: e.g. Bolus 0.5 U"), s)
        }
    }

    static func detail(_ command: QueuedRemoteCommand, now: Date) -> String {
        let message = command.statusMessage ?? ""
        if let meal = command.meal, let detail = mealDetail(command, meal: meal, message: message, now: now) {
            return detail
        }
        switch command.phase(now: now) {
        case .waiting:
            return String(format: String(localized: "Sent at %@. Loop fetches it on its next run (every 5 min), or at once if the push gets through. It can be given until %@.", table: "RemoteCommandInbox", comment: "1: sent time, 2: expiration time"), time(command.sentAt), time(command.expiration))
        case .giving:
            return String(localized: "Don't send again: this one is being given.", table: "RemoteCommandInbox")
        case .given:
            if command.seenInNightscout != nil {
                return String(format: String(localized: "Sent at %@. The bolus is in Nightscout.", table: "RemoteCommandInbox", comment: "1: sent time"), time(command.sentAt))
            }
            return String(format: String(localized: "Sent at %@. Loop confirmed it.", table: "RemoteCommandInbox"), time(command.sentAt))
        case .failed, .rejected:
            return String(format: String(localized: "Nothing was given. Loop said: %@ It is safe to send again.", table: "RemoteCommandInbox", comment: "1: Loop's message"), message)
        case .stopped:
            return DoseGuardText.stoppedDetail(command.stoppedBy ?? [])
        case .uncertain:
            return String(format: String(localized: "The pump did not confirm (%@). Check the pump and the graph before giving more.", table: "RemoteCommandInbox"), message)
        case .cancelled:
            return String(localized: "Loop had not fetched it, so nothing was given.", table: "RemoteCommandInbox")
        case .lapsed:
            return String(format: String(localized: "Loop did not fetch it before %@ and will never give it now. Nothing was given; it is safe to send again. Is Loop running and online?", table: "RemoteCommandInbox"), time(command.expiration))
        case .noAnswer:
            return String(localized: "It may have been given. Check the graph before sending again.", table: "RemoteCommandInbox")
        case .pushWaiting:
            return String(format: String(localized: "This Loop can't answer, so LoopFollow looks for the bolus in Nightscout. Don't send again before %@.", table: "RemoteCommandInbox", comment: "1: expiration time"), time(command.expiration))
        case .pushLapsed:
            return String(format: String(localized: "Loop could take it until %@, and no bolus of that size has shown up since. Most likely it was not given; check the graph before sending again.", table: "RemoteCommandInbox", comment: "1: expiration time"), time(command.expiration))
        case .savedWithoutBolus, .carbsSavedBolusFailed:
            // Only for meals, told in `mealDetail`.
            return message
        }
    }

    /// What is different about a meal with bolus: the carbs may be in Loop even when the bolus is not.
    private static func mealDetail(_ command: QueuedRemoteCommand, meal: MealBolusDetails, message: String, now: Date) -> String? {
        switch command.phase(now: now) {
        case .given:
            guard let delivered = meal.deliveredUnits, delivered < meal.approvedUnits - 0.001 else { return nil }
            return String(format: String(localized: "Sent at %@. You approved up to %@ U; Loop worked out %@ U with the meal.", table: "RemoteCommandInbox", comment: "1: sent time, 2: approved units, 3: given units"), time(command.sentAt), units(meal.approvedUnits), units(delivered))
        case .savedWithoutBolus:
            if let recommended = meal.recommendedUnits {
                return String(format: String(localized: "Loop saved the carbs and worked out %@ U with the meal, so it gave no bolus.", table: "RemoteCommandInbox", comment: "1: Loop's recommendation"), units(recommended))
            }
            return String(localized: "Loop saved the carbs but gave no bolus.", table: "RemoteCommandInbox")
        case .carbsSavedBolusFailed:
            return String(format: String(localized: "Loop saved %@ g but did not give the bolus. Loop said: %@ Don't send the carbs again; give a bolus on its own if one is needed.", table: "RemoteCommandInbox", comment: "1: grams, 2: Loop's message"), grams(meal.carbs), message)
        case .uncertain:
            return String(format: String(localized: "The carbs are saved. The pump did not confirm the bolus (%@). Check the pump and the graph before giving more, and don't send the carbs again.", table: "RemoteCommandInbox", comment: "1: Loop's message"), message)
        case .noAnswer:
            return String(localized: "The carbs and the bolus may both have been given. Check the graph and the meals before sending anything again.", table: "RemoteCommandInbox")
        case .failed, .rejected:
            return String(format: String(localized: "Neither the carbs nor the bolus were saved. Loop said: %@ It is safe to send again.", table: "RemoteCommandInbox", comment: "1: Loop's message"), message)
        default:
            return nil
        }
    }

    /// Only the answers worth a notification.
    static func notification(_ command: QueuedRemoteCommand, now: Date) -> (title: String, body: String)? {
        switch command.phase(now: now) {
        case .given, .failed, .rejected, .stopped, .uncertain, .lapsed, .noAnswer, .savedWithoutBolus, .carbsSavedBolusFailed:
            return (title(command, now: now), detail(command, now: now))
        default:
            return nil
        }
    }

    static func summary(bolusUnits units: Double) -> String {
        String(format: String(localized: "Bolus %@ U", table: "RemoteCommandInbox", comment: "1: units"), Localizer.formatToLocalizedString(units, maxFractionDigits: 2, minFractionDigits: 0))
    }

    /// «Måltid 45 g + 3,25 E».
    static func summary(mealCarbs carbs: Double, units: Double) -> String {
        String(format: String(localized: "Meal %@ g + %@ U", table: "RemoteCommandInbox", comment: "1: grams, 2: units"), grams(carbs), self.units(units))
    }

    static func grams(_ value: Double) -> String {
        Localizer.formatToLocalizedString(value, maxFractionDigits: 1, minFractionDigits: 0)
    }

    static func units(_ value: Double) -> String {
        Localizer.formatToLocalizedString(value, maxFractionDigits: 2, minFractionDigits: 2)
    }
}
