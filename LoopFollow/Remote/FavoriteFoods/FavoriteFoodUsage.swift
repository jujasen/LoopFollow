// LoopFollow
// FavoriteFoodUsage.swift

import Foundation

/// Which favorite foods are eaten most, so the carb screen shows only those and the rest are under
/// «Browse all favorites». Counted the way Loop counts them (Loop's `FavoriteFoodUsage`): one
/// serving per carb entry whose dish name in `foodType` is the favorite's name, over the last 90
/// days, so a food logged in Loop counts the same as one sent from here.
enum FavoriteFoodUsage {
    /// The carb screen shows this many foods.
    static let quickPickCount = 10
    /// Servings older than this no longer count, so what is eaten now rises to the top.
    static let window: TimeInterval = 90 * 24 * 3600
    /// Two entries this close are one serving.
    static let sameServing: TimeInterval = 60

    /// Food id → dates it was logged.
    typealias Log = [String: [Date]]

    struct LoggedEntry: Equatable {
        var foodType: String?
        var date: Date
    }

    static func food(for foodType: String?, in favorites: [StoredFavoriteFood]) -> StoredFavoriteFood? {
        let name = CarbFoodLabel(foodType: foodType).name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return favorites.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `log` with `entries` added; old servings and foods no longer favorites dropped.
    static func recording(_ entries: [LoggedEntry], favorites: [StoredFavoriteFood], into log: Log, now: Date) -> Log {
        let ids = Set(favorites.map(\.id))
        let oldest = now.addingTimeInterval(-window)
        var log = log.filter { ids.contains($0.key) }
        for entry in entries where entry.date >= oldest && entry.date <= now.addingTimeInterval(3600) {
            guard let food = food(for: entry.foodType, in: favorites) else { continue }
            var dates = log[food.id] ?? []
            if !dates.contains(where: { abs($0.timeIntervalSince(entry.date)) < sameServing }) {
                dates.append(entry.date)
            }
            log[food.id] = dates
        }
        return log.mapValues { $0.filter { $0 >= oldest }.sorted() }.filter { !$0.value.isEmpty }
    }

    /// The `limit` favorites eaten most often lately: most servings first, then the most recently
    /// eaten. Foods never logged fill the remaining places in their stored order.
    static func mostUsed(_ favorites: [StoredFavoriteFood], log: Log, now: Date, limit: Int = quickPickCount) -> [StoredFavoriteFood] {
        let oldest = now.addingTimeInterval(-window)
        let ranked = favorites.enumerated().sorted { a, b in
            let aDates = (log[a.element.id] ?? []).filter { $0 >= oldest }
            let bDates = (log[b.element.id] ?? []).filter { $0 >= oldest }
            if aDates.count != bDates.count { return aDates.count > bDates.count }
            let aLast = aDates.max() ?? .distantPast, bLast = bDates.max() ?? .distantPast
            if aLast != bLast { return aLast > bLast }
            return a.offset < b.offset
        }
        return Array(ranked.prefix(limit).map(\.element))
    }

    // MARK: On the phone

    private static let logKey = "favoriteFoodUsage"
    private static let seededKey = "favoriteFoodUsageSeededAt"

    static var storedLog: Log {
        get {
            guard let stored = UserDefaults.standard.dictionary(forKey: logKey) as? [String: [Double]] else { return [:] }
            return stored.mapValues { $0.map(Date.init(timeIntervalSince1970:)) }
        }
        set {
            UserDefaults.standard.set(newValue.mapValues { $0.map(\.timeIntervalSince1970) }, forKey: logKey)
        }
    }

    /// Called with the carb entries of every treatment download.
    static func record(carbEntries: [[String: AnyObject]], now: Date = Date()) {
        let entries = carbEntries.compactMap { entry -> LoggedEntry? in
            guard let date = NightscoutUtils.treatmentDate(from: entry) else { return nil }
            return LoggedEntry(foodType: entry["foodType"] as? String, date: date)
        }
        storedLog = recording(entries, favorites: Storage.shared.favoriteFoods.value, into: storedLog, now: now)
    }

    /// The screen downloads only a day or so of treatments, so the 90 days are read from
    /// Nightscout once a week to start the count.
    static func seedIfNeeded(now: Date = Date()) async {
        let seededAt = UserDefaults.standard.object(forKey: seededKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(seededAt) > 7 * 24 * 3600, !Storage.shared.favoriteFoods.value.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        guard let url = NightscoutUtils.constructURL(baseURL: Storage.shared.url.value, token: Storage.shared.token.value, endpoint: "/api/v1/treatments.json", parameters: [
            "find[carbs][$gt]": "0",
            "find[created_at][$gte]": formatter.string(from: now.addingTimeInterval(-window)),
            "count": "5000",
        ]) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: AnyObject]]
        else { return }
        await MainActor.run {
            record(carbEntries: entries, now: now)
            UserDefaults.standard.set(now, forKey: seededKey)
        }
    }
}
