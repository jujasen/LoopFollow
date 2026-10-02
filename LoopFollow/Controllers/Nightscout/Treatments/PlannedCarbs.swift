// LoopFollow
// PlannedCarbs.swift

import Foundation

/// A "later carbs" plan from Loop: a small slow carb entry Loop will add by itself after a meal,
/// once glucose is high enough and not falling, somewhere between `dueDate` and `expiresAt`.
///
/// While a plan waits, Loop keeps one "Planned Carbs" treatment for it in Nightscout and deletes
/// it when the plan is added (the real carb entry then uploads as usual), dropped or cancelled.
/// The treatment deliberately has no `carbs` field: a plan is not carbs yet, so it must never
/// reach COB, today's carbs, stats or the treatment list. Loop writes it with the same field
/// names — change both apps together.
struct PlannedCarb: Equatable {
    static let eventType = "Planned Carbs"

    /// The meal the plan belongs to.
    var id: String
    /// Earliest time Loop may add the carbs.
    var dueDate: TimeInterval
    /// Latest time; after this Loop drops the plan.
    var expiresAt: TimeInterval
    var grams: Double
    /// Minutes, as on a carb entry.
    var absorptionTime: Int
    /// The meal's emoji and dish name (see `CarbFoodLabel`).
    var foodType: String?
    var reason: String?

    /// Reads one "Planned Carbs" treatment. Nil when it is missing its time, expiry or grams, or
    /// when it has already expired.
    init?(treatment entry: [String: AnyObject], now: TimeInterval) {
        guard entry["eventType"] as? String == Self.eventType,
              let dueString = (entry["timestamp"] as? String) ?? (entry["created_at"] as? String),
              let due = NightscoutUtils.parseDate(dueString),
              let expiresString = entry["expiresAt"] as? String,
              let expires = NightscoutUtils.parseDate(expiresString),
              let grams = Self.number(entry["plannedCarbs"]), grams > 0
        else { return nil }

        let expiresAt = expires.timeIntervalSince1970
        guard expiresAt > now else { return nil }

        id = (entry["plannedCarbsID"] as? String) ?? (entry["_id"] as? String) ?? ""
        dueDate = due.timeIntervalSince1970
        self.expiresAt = max(expiresAt, dueDate)
        self.grams = grams
        absorptionTime = Int(Self.number(entry["absorptionTime"]) ?? 0)
        foodType = entry["foodType"] as? String
        reason = entry["reason"] as? String
    }

    /// The plans still waiting, oldest first.
    static func parse(_ entries: [[String: AnyObject]], now: TimeInterval) -> [PlannedCarb] {
        entries.compactMap { PlannedCarb(treatment: $0, now: now) }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

extension MainViewController {
    // NS Planned Carbs Response Processor
    func processNSPlannedCarbs(entries: [[String: AnyObject]]) {
        // Because it's a small array, we're going to destroy and reload every time.
        plannedCarbData.removeAll()
        var lastFoundIndex = 0

        for plan in PlannedCarb.parse(entries, now: dateTimeUtils.getNowTimeIntervalUTC()) {
            // Same lane as a carb dot. A plan is usually due after the latest reading, where
            // there is no nearest BG yet, so it rides on the latest one.
            var sgv = 100.0
            if let latest = bgData.last, plan.dueDate >= latest.date {
                sgv = Double(latest.sgv)
            } else {
                let nearest = findNearestBGbyTime(needle: plan.dueDate, haystack: bgData, startingIndex: lastFoundIndex)
                lastFoundIndex = nearest.foundIndex
                sgv = nearest.sgv
            }
            let offset = sgv < Double(calculateMaxBgGraphValue() - 100) ? 20 : -50
            plannedCarbData.append(plannedCarbGraphStruct(plan: plan, sgv: Int(sgv) + offset))
        }

        if Storage.shared.graphCarbs.value {
            updateCarbGraph()
        }
    }
}
