// LoopFollow
// AIBolusSuggestion.swift

// Loop's meal watch follows a meal and, when glucose runs away, suggests a bolus on Walter's
// phone. While a suggestion is open Loop keeps it in Nightscout as one treatment (contract in
// Loop's MealWatch.swift, `MealWatchTreatment`):
//
//   eventType     "AI Bolus Suggestion"
//   created_at    when it was made (also `timestamp`), ISO 8601 UTC
//   expiresAt     when it lapses, about 20 minutes later
//   suggestionID  stays the same for the suggestion
//   units         the suggested bolus
//   reason        why, one sentence
//   glucose       mmol/L when made (optional)
//   loopUnits     what Loop itself recommended (optional)
//   foodType, mealName, mealDate, mealCarbs   the meal it is about (optional)
//
// It carries no insulin or carbs fields, so nothing counts it as a treatment. Loop deletes it
// when it is given, declined on Walter's phone, or lapses.

import Foundation
import UserNotifications

struct AIBolusSuggestion: Equatable, Identifiable {
    static let eventType = "AI Bolus Suggestion"

    var id: String
    var date: Date
    var expiresAt: Date
    var units: Double
    var reason: String
    var glucoseMmol: Double?
    var loopUnits: Double?
    var foodType: String?
    var mealName: String?
    var mealDate: Date?
    var mealCarbs: Double?

    /// Reads one treatment. Nil when it is another kind, misses its id, amount or expiry, has an
    /// amount that is not a positive finite number, or has lapsed.
    init?(treatment entry: [String: AnyObject], now: Date) {
        guard entry["eventType"] as? String == Self.eventType,
              let id = entry["suggestionID"] as? String, !id.isEmpty,
              let units = Self.number(entry["units"]), units > 0,
              let expiresString = entry["expiresAt"] as? String,
              let expiresAt = NightscoutUtils.parseDate(expiresString),
              expiresAt > now
        else { return nil }

        let dateString = (entry["timestamp"] as? String) ?? (entry["created_at"] as? String)
        self.id = id
        date = dateString.flatMap(NightscoutUtils.parseDate) ?? now
        self.expiresAt = expiresAt
        self.units = units
        reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        glucoseMmol = Self.number(entry["glucose"])
        loopUnits = Self.number(entry["loopUnits"])
        foodType = (entry["foodType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        mealName = (entry["mealName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        mealDate = (entry["mealDate"] as? String).flatMap(NightscoutUtils.parseDate)
        mealCarbs = Self.number(entry["mealCarbs"])
    }

    init(id: String, date: Date, expiresAt: Date, units: Double, reason: String, foodType: String? = nil, mealName: String? = nil) {
        self.id = id
        self.date = date
        self.expiresAt = expiresAt
        self.units = units
        self.reason = reason
        self.foodType = foodType
        self.mealName = mealName
    }

    /// The open suggestions, oldest first, one per id (the newest copy if Nightscout has two).
    static func parse(_ entries: [[String: AnyObject]], now: Date) -> [AIBolusSuggestion] {
        var byID: [String: AIBolusSuggestion] = [:]
        for suggestion in entries.compactMap({ AIBolusSuggestion(treatment: $0, now: now) }) {
            if let existing = byID[suggestion.id], existing.date >= suggestion.date { continue }
            byID[suggestion.id] = suggestion
        }
        return byID.values.sorted { $0.date < $1.date }
    }

    /// "🥛 Melk", or the meal's name when it has no food type, or empty.
    var meal: String {
        CarbFoodLabel(foodType: foodType).foodType ?? mealName ?? ""
    }

    /// Only finite numbers: "inf" or "nan" would reach the bolus screen.
    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let double = value as? Double { number = double }
        else if let int = value as? Int { number = Double(int) }
        else if let string = value as? String { number = Double(string) }
        else { number = nil }
        guard let number, number.isFinite else { return nil }
        return number
    }
}

/// The words for a suggestion, in their own table (AIBolusSuggestion.xcstrings).
enum AIBolusSuggestionText {
    static func units(_ units: Double) -> String {
        Localizer.formatToLocalizedString(units, maxFractionDigits: 2)
    }

    /// "✨ Forslag: 0,4 E til 🥛 Melk"
    static func title(_ suggestion: AIBolusSuggestion) -> String {
        let meal = suggestion.meal
        guard !meal.isEmpty else {
            return String(format: String(localized: "✨ Suggestion: %@ U", table: "AIBolusSuggestion", comment: "AI bolus suggestion without a meal name (1: units)"), units(suggestion.units))
        }
        return String(format: String(localized: "✨ Suggestion: %1$@ U for %2$@", table: "AIBolusSuggestion", comment: "AI bolus suggestion (1: units)(2: the meal)"), units(suggestion.units), meal)
    }

    /// "Faller bort kl. 21:40"
    static func lapses(_ suggestion: AIBolusSuggestion) -> String {
        String(format: String(localized: "Lapses at %@", table: "AIBolusSuggestion", comment: "When an AI bolus suggestion lapses (1: time)"), suggestion.expiresAt.formatted(date: .omitted, time: .shortened))
    }

    static var review: String {
        String(localized: "Review", table: "AIBolusSuggestion", comment: "Button that opens the bolus screen filled in with an AI suggestion")
    }

    static var decline: String {
        String(localized: "Decline", table: "AIBolusSuggestion", comment: "Button that hides an AI bolus suggestion on this phone")
    }
}

/// The open suggestions for the card, which ones were declined here, and which were already
/// announced with a notification.
final class AIBolusSuggestionStore: ObservableObject {
    static let shared = AIBolusSuggestionStore()

    /// Declined and announced ids are kept this long, well past any suggestion's life.
    static let memory: TimeInterval = 24 * 3600

    @Published private(set) var suggestions: [AIBolusSuggestion] = []
    @Published private(set) var dismissed: [String: Date]
    /// The suggestion whose bolus screen is open.
    @Published var reviewing: AIBolusSuggestion?

    private var notified: [String: Date]
    /// An id from a tapped notification, for when the suggestion is read after it.
    private var pendingReviewID: String?

    private let defaults: UserDefaults
    private static let dismissedKey = "aiBolusSuggestionsDismissed"
    private static let notifiedKey = "aiBolusSuggestionsNotified"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = Self.read(Self.dismissedKey, from: defaults)
        notified = Self.read(Self.notifiedKey, from: defaults)
    }

    /// The ones to show: not declined here and not lapsed.
    func visible(now: Date = Date()) -> [AIBolusSuggestion] {
        suggestions.filter { dismissed[$0.id] == nil && $0.expiresAt > now }
    }

    var hasOpenSuggestion: Bool { !visible().isEmpty }

    /// Takes what Nightscout has now and returns the suggestions seen for the first time,
    /// which are then counted as announced.
    @discardableResult
    func update(_ all: [AIBolusSuggestion], now: Date = Date()) -> [AIBolusSuggestion] {
        if all != suggestions { suggestions = all }

        let fresh = all.filter { notified[$0.id] == nil && dismissed[$0.id] == nil && $0.expiresAt > now }
        var notified = self.notified.filter { now.timeIntervalSince($0.value) < Self.memory }
        for suggestion in fresh {
            notified[suggestion.id] = now
        }
        if notified != self.notified { setNotified(notified) }

        let keptDismissed = dismissed.filter { now.timeIntervalSince($0.value) < Self.memory }
        if keptDismissed != dismissed { setDismissed(keptDismissed) }

        if let id = pendingReviewID, let suggestion = visible(now: now).first(where: { $0.id == id }) {
            pendingReviewID = nil
            reviewing = suggestion
        }
        if let reviewing, !all.contains(where: { $0.id == reviewing.id }) {
            // Given, declined on Walter's phone, or lapsed: the screen stays, but not as this one.
            self.reviewing = nil
        }
        return fresh
    }

    /// «Avslå»: hides it on this phone. Loop is not told; it lapses there on its own.
    func dismiss(_ suggestion: AIBolusSuggestion, at date: Date = Date()) {
        var dismissed = self.dismissed
        dismissed[suggestion.id] = date
        setDismissed(dismissed)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [AIBolusSuggestionNotifier.identifier(suggestion.id)])
    }

    /// Opens the bolus screen for it, now or as soon as it has been read.
    func review(id: String) {
        if let suggestion = visible().first(where: { $0.id == id }) {
            reviewing = suggestion
        } else {
            pendingReviewID = id
        }
    }

    private func setDismissed(_ value: [String: Date]) {
        dismissed = value
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedKey)
    }

    private func setNotified(_ value: [String: Date]) {
        notified = value
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: Self.notifiedKey)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
}

/// The notification for a new suggestion.
enum AIBolusSuggestionNotifier {
    static let userInfoKey = "aiBolusSuggestionID"

    static func identifier(_ id: String) -> String { "aiBolusSuggestion-\(id)" }

    static func notify(_ suggestion: AIBolusSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = AIBolusSuggestionText.title(suggestion)
        content.body = suggestion.reason
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = [userInfoKey: suggestion.id]
        let request = UNNotificationRequest(identifier: identifier(suggestion.id), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        LogManager.shared.log(category: .general, message: "AI bolus suggestion \(suggestion.id): \(suggestion.units) U")
    }
}

extension MainViewController {
    // NS AI Bolus Suggestion Response Processor
    func processNSAIBolusSuggestions(entries: [[String: AnyObject]]) {
        let fresh = AIBolusSuggestionStore.shared.update(AIBolusSuggestion.parse(entries, now: Date()))
        for suggestion in fresh {
            AIBolusSuggestionNotifier.notify(suggestion)
        }
    }
}
