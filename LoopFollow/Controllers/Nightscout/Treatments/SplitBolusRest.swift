// LoopFollow
// SplitBolusRest.swift

import Foundation

/// The rest of a split bolus in Loop: a meal (evening milk) is bolused partly when eaten, and the
/// rest about two hours later for the rise fat brings. Loop offers the rest on the phone when it
/// is due; while it waits, it keeps one "Split Bolus Rest" treatment for it in Nightscout, so a
/// parent can see it here and log it from this phone.
///
/// Loop writes these fields (`Loop/Managers/SplitBolusNightscout.swift`) — change both apps
/// together:
/// - `created_at`/`timestamp`: when the rest is due; `expiresAt`: when Loop lets it go
/// - `splitBolusID`, `state` ("waiting", "due" or "postponed": glucose was low or falling when
///   due, checked again at `created_at`)
/// - `restCarbs`, `restUnits` (rough insulin, may be missing), `restFoodType`, `absorptionTime`
///   (minutes)
/// - `foodType`, `mealName`, `mealDate`, `mealCarbs`, `nowCarbs`: the meal it belongs to
///
/// It has no `carbs` field and never counts as carbs. Loop deletes it once the rest is given,
/// skipped, expires or the split is called off. A remote carb entry with exactly `restFoodType`
/// is what Loop takes for the rest, so that is what LoopFollow sends.
struct SplitBolusRest: Equatable, Identifiable {
    static let eventType = "Split Bolus Rest"
    /// Loop's absorption time for the rest, when the treatment has none.
    static let defaultAbsorptionMinutes = 180

    enum State: String {
        case waiting
        case due
        case postponed
    }

    var id: String
    var dueDate: TimeInterval
    var expiresAt: TimeInterval
    var state: State
    var grams: Double
    var units: Double?
    /// The `foodType` the rest is logged with, "🥛🍼 Melk (resten)".
    var restFoodType: String
    /// Minutes.
    var absorptionTime: Int
    /// The meal's emoji and name.
    var foodType: String?
    var mealName: String
    var mealDate: TimeInterval?
    var mealCarbs: Double?
    var nowCarbs: Double?

    /// Reads one "Split Bolus Rest" treatment. Nil when it is missing its time, expiry or grams,
    /// or when it has already expired.
    init?(treatment entry: [String: AnyObject], now: TimeInterval) {
        guard entry["eventType"] as? String == Self.eventType,
              let dueString = (entry["timestamp"] as? String) ?? (entry["created_at"] as? String),
              let due = NightscoutUtils.parseDate(dueString),
              let expiresString = entry["expiresAt"] as? String,
              let expires = NightscoutUtils.parseDate(expiresString),
              let grams = Self.number(entry["restCarbs"]), grams > 0
        else { return nil }

        let expiresAt = expires.timeIntervalSince1970
        guard expiresAt > now else { return nil }

        id = (entry["splitBolusID"] as? String) ?? (entry["_id"] as? String) ?? ""
        dueDate = due.timeIntervalSince1970
        self.expiresAt = max(expiresAt, dueDate)
        state = (entry["state"] as? String).flatMap(State.init(rawValue:)) ?? .waiting
        self.grams = grams
        units = Self.number(entry["restUnits"])
        foodType = entry["foodType"] as? String
        let meal = CarbFoodLabel(foodType: foodType)
        mealName = (entry["mealName"] as? String) ?? meal.name
        restFoodType = (entry["restFoodType"] as? String)
            ?? CarbFoodLabel(emoji: meal.emoji.isEmpty ? "✂️" : meal.emoji, name: meal.name.isEmpty ? "Rest" : meal.name + " (rest)").foodType
            ?? "✂️ Rest"
        absorptionTime = Self.number(entry["absorptionTime"]).map { Int($0) } ?? Self.defaultAbsorptionMinutes
        mealDate = (entry["mealDate"] as? String).flatMap(NightscoutUtils.parseDate)?.timeIntervalSince1970
        mealCarbs = Self.number(entry["mealCarbs"])
        nowCarbs = Self.number(entry["nowCarbs"])
    }

    /// The rests still waiting, earliest first.
    static func parse(_ entries: [[String: AnyObject]], now: TimeInterval) -> [SplitBolusRest] {
        entries.compactMap { SplitBolusRest(treatment: $0, now: now) }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// True once a carb entry for the rest is in Nightscout: logged on the phone or sent from
    /// here, before Loop has caught up and deleted the treatment.
    func isLogged(in carbEntries: [[String: AnyObject]]) -> Bool {
        let since = (mealDate ?? dueDate - 3 * 3600) - 60
        return carbEntries.contains { entry in
            guard (entry["foodType"] as? String) == restFoodType,
                  let dateString = (entry["timestamp"] as? String) ?? (entry["created_at"] as? String),
                  let date = NightscoutUtils.parseDate(dateString)
            else { return false }
            return date.timeIntervalSince1970 >= since
        }
    }

    var isDue: Bool { state == .due }

    /// The remote carb entry that logs the rest now.
    func payload(otp: String, at date: Date) -> LoopAPNSPayload {
        LoopAPNSPayload(
            type: .carbs,
            carbsAmount: grams,
            absorptionTime: Double(absorptionTime) / 60,
            foodType: restFoodType,
            consumedDate: date,
            otp: otp
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

/// The rests to show, for the card on the main screen. Kept apart from the chart so the card
/// can observe it alone.
final class SplitBolusRestStore: ObservableObject {
    static let shared = SplitBolusRestStore()

    /// A rest sent from here stays marked as sent this long while Nightscout has no carb entry
    /// for it yet; after that it can be sent again.
    static let sentHold: TimeInterval = 15 * 60

    @Published private(set) var rests: [SplitBolusRest] = []
    /// When each rest was sent from this phone, by split id.
    @Published private(set) var sent: [String: Date]

    private let defaults: UserDefaults
    private static let sentKey = "splitBolusRestsSent"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.sentKey) as? [String: Double] ?? [:]
        sent = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The rests waiting in Nightscout that are not logged yet.
    static func visible(_ rests: [SplitBolusRest], carbEntries: [[String: AnyObject]]) -> [SplitBolusRest] {
        rests.filter { !$0.isLogged(in: carbEntries) }
    }

    func update(rests all: [SplitBolusRest], carbEntries: [[String: AnyObject]], now: Date = Date()) {
        let shown = Self.visible(all, carbEntries: carbEntries)
        if shown != rests { rests = shown }
        // Forget sends of rests that are gone.
        let ids = Set(all.map(\.id))
        let kept = sent.filter { ids.contains($0.key) || now.timeIntervalSince($0.value) < Self.sentHold }
        if kept != sent { setSent(kept) }
    }

    /// When the rest was sent from here, while that still holds.
    func sentAt(_ rest: SplitBolusRest, now: Date = Date()) -> Date? {
        guard let date = sent[rest.id], now.timeIntervalSince(date) < Self.sentHold else { return nil }
        return date
    }

    func markSent(_ rest: SplitBolusRest, at date: Date = Date()) {
        var sent = self.sent
        sent[rest.id] = date
        setSent(sent)
    }

    private func setSent(_ value: [String: Date]) {
        sent = value
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: Self.sentKey)
    }
}

extension MainViewController {
    // NS Split Bolus Rest Response Processor
    func processNSSplitBolusRests(entries: [[String: AnyObject]], carbEntries: [[String: AnyObject]]) {
        let rests = SplitBolusRest.parse(entries, now: dateTimeUtils.getNowTimeIntervalUTC())
        SplitBolusRestStore.shared.update(rests: rests, carbEntries: carbEntries)

        splitBolusRestData.removeAll()
        var lastFoundIndex = 0
        for rest in SplitBolusRestStore.shared.rests {
            // Same lane as a carb dot, riding on the latest reading when due after it.
            var sgv = 100.0
            if let latest = bgData.last, rest.dueDate >= latest.date {
                sgv = Double(latest.sgv)
            } else {
                let nearest = findNearestBGbyTime(needle: rest.dueDate, haystack: bgData, startingIndex: lastFoundIndex)
                lastFoundIndex = nearest.foundIndex
                sgv = nearest.sgv
            }
            let offset = sgv < Double(calculateMaxBgGraphValue() - 100) ? 20 : -50
            splitBolusRestData.append(splitBolusRestGraphStruct(rest: rest, sgv: Int(sgv) + offset))
        }

        if Storage.shared.graphCarbs.value {
            updateCarbGraph()
        }
    }
}
