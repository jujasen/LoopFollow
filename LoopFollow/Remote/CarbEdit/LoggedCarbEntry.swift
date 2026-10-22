// LoopFollow
// LoggedCarbEntry.swift

import Foundation

/// A carb entry Loop logged and uploaded to Nightscout, which Loop can change or delete again
/// through the `carbs-edit` remote command.
///
/// Loop finds the entry by the `syncIdentifier` it uploads with every carb treatment, so only
/// entries that carry one can be edited — Loop's own, including remote carbs sent from here.
/// Carbs typed into Nightscout's careportal are not in Loop and have none.
struct LoggedCarbEntry: Identifiable, Equatable {
    let syncIdentifier: String
    let grams: Double
    let date: Date
    /// Minutes, as Nightscout has it; nil when the treatment has none.
    let absorptionMinutes: Double?
    let foodType: String?

    var id: String { syncIdentifier }

    /// How far back an entry can be changed; the same as Loop accepts.
    static let lookback: TimeInterval = 24 * 60 * 60

    /// Loop's carb treatments from the last day that carry a sync identifier, newest first.
    static func parse(_ entries: [[String: AnyObject]], now: Date = Date()) -> [LoggedCarbEntry] {
        let oldest = now.addingTimeInterval(-lookback)
        return entries.compactMap { entry -> LoggedCarbEntry? in
            guard let syncIdentifier = entry["syncIdentifier"] as? String, !syncIdentifier.isEmpty,
                  let grams = number(entry["carbs"]), grams > 0,
                  let dateString = (entry["timestamp"] as? String) ?? (entry["created_at"] as? String),
                  let date = NightscoutUtils.parseDate(dateString),
                  date >= oldest
            else { return nil }
            let foodType = (entry["foodType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return LoggedCarbEntry(syncIdentifier: syncIdentifier, grams: grams, date: date, absorptionMinutes: number(entry["absorptionTime"]), foodType: foodType)
        }
        .sorted { $0.date > $1.date }
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

/// What the caregiver set on the edit screen, and the `carbs-edit` block that carries the change.
struct CarbEditDraft: Equatable {
    var grams: Double
    var date: Date
    /// Hours.
    var absorptionHours: Double
    var emoji: String
    var name: String

    /// The absorption a treatment without one is shown with; Loop uses its own medium default then.
    static let defaultAbsorptionHours = 3.0

    init(entry: LoggedCarbEntry) {
        grams = entry.grams
        date = entry.date
        absorptionHours = (entry.absorptionMinutes ?? Self.defaultAbsorptionHours * 60) / 60
        let label = CarbFoodLabel(foodType: entry.foodType)
        emoji = label.emoji
        name = label.name
    }

    var foodType: String? {
        CarbFoodLabel(emoji: emoji, name: name).foodType
    }

    /// Only the values that differ from `entry`, so Loop keeps everything else exactly as it is;
    /// nil when nothing changed. `date` should already carry the seconds to send.
    func changes(from entry: LoggedCarbEntry) -> [String: Any]? {
        var block = [String: Any]()
        if abs(grams - entry.grams) >= 0.05 {
            block["carbs"] = grams
        }
        if abs(date.timeIntervalSince(entry.date)) >= 60 {
            block["start-time"] = Self.formatDate(date)
        }
        let original = CarbEditDraft(entry: entry)
        if abs(absorptionHours - original.absorptionHours) >= 0.01 {
            block["absorption-time"] = absorptionHours
        }
        if foodType != CarbFoodLabel(foodType: entry.foodType).foodType {
            // An empty string clears the food type in Loop.
            block["food-type"] = foodType ?? ""
        }
        guard !block.isEmpty else { return nil }
        block["sync-identifier"] = entry.syncIdentifier
        return block
    }

    static func deletion(of entry: LoggedCarbEntry) -> [String: Any] {
        ["sync-identifier": entry.syncIdentifier, "delete": true]
    }

    /// The format Loop decodes remote command dates with.
    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Loop's recent carb entries for the edit list, and the ones changed from this phone that
/// Nightscout does not show changed yet.
final class LoggedCarbsStore: ObservableObject {
    static let shared = LoggedCarbsStore()

    /// An entry sent from here stays marked as waiting this long while Nightscout still shows it
    /// as it was; after that it can be changed again.
    static let sentHold: TimeInterval = 15 * 60

    @Published private(set) var entries: [LoggedCarbEntry] = []
    /// The entry as it was when a change was sent, and when, by sync identifier.
    @Published private(set) var sent: [String: (entry: LoggedCarbEntry, at: Date)] = [:]

    func update(carbEntries: [[String: AnyObject]], now: Date = Date()) {
        let parsed = LoggedCarbEntry.parse(carbEntries, now: now)
        if parsed != entries { entries = parsed }
        // A change has arrived once Nightscout shows the entry different from when it was sent, or gone.
        let kept = sent.filter { id, value in
            parsed.first(where: { $0.id == id }) == value.entry && now.timeIntervalSince(value.at) < Self.sentHold
        }
        if Set(kept.keys) != Set(sent.keys) { sent = kept }
    }

    func sentAt(_ entry: LoggedCarbEntry, now: Date = Date()) -> Date? {
        guard let value = sent[entry.id], value.entry == entry, now.timeIntervalSince(value.at) < Self.sentHold else { return nil }
        return value.at
    }

    func markSent(_ entry: LoggedCarbEntry, at date: Date = Date()) {
        sent[entry.id] = (entry, date)
    }
}
