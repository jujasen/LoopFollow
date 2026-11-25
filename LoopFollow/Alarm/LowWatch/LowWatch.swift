// LoopFollow
// LowWatch.swift

import Foundation
import SwiftUI
import UserNotifications

/// Loop's low watch («Lavvakt») runs on Walter's phone: when Loop forecasts a low within 20
/// minutes, or glucose is under 4.4 and falling, it suggests 2–6 g of fast carbs. It never
/// enters anything itself. While a suggestion is open Loop keeps it in Nightscout as one
/// treatment (contract in Loop's LowWatchManager.swift, `LowWatchTreatment`):
///
///   eventType       "Low Watch Suggestion"
///   source          "lowWatch"
///   created_at      when it was made (also `timestamp`)
///   expiresAt       when it lapses, half an hour later
///   suggestionID    stays the same for the suggestion
///   grams           the suggested fast carbs
///   glucose         mmol/L when made
///   trigger         "forecast" or "low"
///   lowestForecast  Loop's lowest forecast within 20 minutes (optional)
///   reason          why, one sentence
///
/// It has no `carbs` field, so it never counts as carbs. Loop deletes it when carbs are entered,
/// when it is declined on Walter's phone, or when glucose comes back up. Declining it here
/// deletes it, which Loop takes as declined (needs a token that may delete treatments).
struct LowWatchSuggestion: Equatable, Identifiable {
    static let eventType = "Low Watch Suggestion"

    var id: String
    var date: Date
    var expiresAt: Date
    var grams: Double
    var glucoseMmol: Double?
    var reason: String
    var nsID: String?

    init?(treatment entry: [String: AnyObject], now: Date) {
        guard entry["eventType"] as? String == Self.eventType,
              let id = entry["suggestionID"] as? String, !id.isEmpty,
              let grams = EveningWatch.number(entry["grams"]), grams > 0,
              let expiresAt = (entry["expiresAt"] as? String).flatMap(NightscoutUtils.parseDate),
              expiresAt > now
        else { return nil }
        self.id = id
        date = ((entry["timestamp"] as? String) ?? (entry["created_at"] as? String)).flatMap(NightscoutUtils.parseDate) ?? now
        self.expiresAt = expiresAt
        self.grams = grams
        glucoseMmol = EveningWatch.number(entry["glucose"])
        reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        nsID = entry["_id"] as? String
    }

    init(id: String, date: Date, expiresAt: Date, grams: Double, reason: String, nsID: String? = nil) {
        self.id = id
        self.date = date
        self.expiresAt = expiresAt
        self.grams = grams
        self.reason = reason
        self.nsID = nsID
    }

    /// The newest open suggestion, if any.
    static func latest(in entries: [[String: AnyObject]], now: Date) -> LowWatchSuggestion? {
        entries.compactMap { LowWatchSuggestion(treatment: $0, now: now) }.max { $0.date < $1.date }
    }
}

/// The open suggestion for the card, which ones were declined or answered here, and which were
/// already announced.
final class LowWatchStore: ObservableObject {
    static let shared = LowWatchStore()

    static let memory: TimeInterval = 24 * 3600

    @Published private(set) var suggestion: LowWatchSuggestion?
    @Published private(set) var hidden: [String: Date]
    private var notified: [String: Date]

    private let defaults: UserDefaults
    private static let hiddenKey = "lowWatchHidden"
    private static let notifiedKey = "lowWatchNotified"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Self.read(Self.hiddenKey, from: defaults)
        notified = Self.read(Self.notifiedKey, from: defaults)
    }

    /// The one to show: open, not declined or answered here.
    func visible(now: Date = Date()) -> LowWatchSuggestion? {
        guard let suggestion, hidden[suggestion.id] == nil, suggestion.expiresAt > now else { return nil }
        return suggestion
    }

    /// Takes what Nightscout has now, hides it when carbs were entered after it, and returns it
    /// when it is seen for the first time, which counts it as announced.
    @discardableResult
    func update(_ latest: LowWatchSuggestion?, carbs: [(date: Date, grams: Double)], now: Date = Date()) -> LowWatchSuggestion? {
        if latest != suggestion { suggestion = latest }
        var hidden = self.hidden.filter { now.timeIntervalSince($0.value) < Self.memory }
        var notified = self.notified.filter { now.timeIntervalSince($0.value) < Self.memory }
        defer {
            if hidden != self.hidden { setHidden(hidden) }
            if notified != self.notified { setNotified(notified) }
        }
        guard let latest, latest.expiresAt > now, hidden[latest.id] == nil else { return nil }
        if Self.answered(latest, carbs: carbs) {
            hidden[latest.id] = now
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LowWatchNotifier.identifier(latest.id)])
            return nil
        }
        guard notified[latest.id] == nil else { return nil }
        notified[latest.id] = now
        return latest
    }

    /// Carbs entered in Loop or sent from here since the suggestion: the same rule Loop uses.
    static func answered(_ suggestion: LowWatchSuggestion, carbs: [(date: Date, grams: Double)]) -> Bool {
        carbs.contains { $0.grams >= 1 && $0.date >= suggestion.date.addingTimeInterval(-60) }
    }

    /// «Avslå»: hides it here and deletes it from Nightscout, which Loop takes as declined.
    /// Without write access to Nightscout it is only hidden here.
    func decline(_ suggestion: LowWatchSuggestion, at date: Date = Date()) {
        var hidden = self.hidden
        hidden[suggestion.id] = date
        setHidden(hidden)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [LowWatchNotifier.identifier(suggestion.id)])
        guard let nsID = suggestion.nsID,
              let url = NightscoutUtils.constructURL(baseURL: Storage.shared.url.value, token: Storage.shared.token.value, endpoint: "/api/v1/treatments/\(nsID)", parameters: [:])
        else { return }
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                LogManager.shared.log(category: .general, message: "Low watch suggestion \(suggestion.id) declined in Nightscout: \(status)")
            } catch {
                LogManager.shared.log(category: .general, message: "Low watch suggestion \(suggestion.id) could not be declined in Nightscout: \(error.localizedDescription)")
            }
        }
    }

    private func setHidden(_ value: [String: Date]) {
        hidden = value
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: Self.hiddenKey)
    }

    private func setNotified(_ value: [String: Date]) {
        notified = value
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: Self.notifiedKey)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
}

/// A time-sensitive notification with sound for each new suggestion: a low is coming.
enum LowWatchNotifier {
    static func identifier(_ id: String) -> String { "lowWatch-\(id)" }

    static func notify(_ suggestion: LowWatchSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = LowWatchText.title(grams: suggestion.grams)
        content.body = suggestion.reason
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier(suggestion.id), content: content, trigger: nil))
        LogManager.shared.log(category: .general, message: "Low watch suggestion \(suggestion.id): \(suggestion.grams) g")
    }
}

enum LowWatchText {
    static let symbol = "🍭"

    /// "🍭 Lavvakt: 3 g rask karbo?"
    static func title(grams: Double) -> String {
        String(format: String(localized: "🍭 Low watch: %@ g fast carbs?", table: "LowWatch", comment: "Title of a low watch suggestion (1: grams)"), Localizer.formatToLocalizedString(grams, maxFractionDigits: 0))
    }

    static var hint: String {
        String(localized: "Loop on Walter's phone suggests this. Whoever is with him gives the carbs and enters them; then it goes from here too.", table: "LowWatch", comment: "Under a low watch suggestion")
    }

    static var decline: String {
        String(localized: "Decline", table: "LowWatch", comment: "Button: declines the low watch's suggestion, here and in Loop")
    }
}

/// Loop's open low watch suggestion on the main screen, as a compact card
/// like the others on Home. Tap it for who gives the carbs.
struct LowWatchCard: View {
    @ObservedObject var store = LowWatchStore.shared
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let suggestion = store.visible(now: context.date) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LowWatchText.title(grams: suggestion.grams))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if !suggestion.reason.isEmpty {
                            Text(suggestion.reason)
                                .font(.footnote)
                                .lineLimit(expanded ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if expanded {
                            Text(LowWatchText.hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(LowWatchText.decline) {
                        withAnimation { store.decline(suggestion) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .homeCard(padding: 10)
                .overlay(alignment: .leading) { HomeCardAccent(color: HomePalette.carbs) }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                .padding(.bottom, 8)
            }
        }
    }
}

extension MainViewController {
    /// Loop's low watch: the card, and a notification the first time a suggestion is seen.
    func processNSLowWatch(entries: [[String: AnyObject]], carbs: [[String: AnyObject]], now: Date = Date()) {
        let entered: [(date: Date, grams: Double)] = carbs.compactMap { entry in
            guard let grams = EveningWatch.number(entry["carbs"]) else { return nil }
            // When it was entered: carbs entered now for a meal later still answer it, as in Loop.
            let entered = ((entry["userEnteredAt"] as? String) ?? (entry["created_at"] as? String)).flatMap(NightscoutUtils.parseDate)
            guard let date = entered ?? NightscoutUtils.treatmentDate(from: entry) else { return nil }
            return (date, grams)
        }
        if let fresh = LowWatchStore.shared.update(LowWatchSuggestion.latest(in: entries, now: now), carbs: entered, now: now) {
            LowWatchNotifier.notify(fresh)
        }
    }
}
