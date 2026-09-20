// LoopFollow
// FavoriteFood.swift

import Foundation

/// One recorded amount of a favorite food, e.g. "half a slice" at 8 g.
///
/// A food always has at least one portion. Foods that come in several sizes — a whole, a half and
/// a quarter slice of bread — carry one portion per size, each with its own carb amount, so the
/// same food can be sent at different amounts without duplicating it in the list.
struct FavoriteFoodPortion: Identifiable, Codable, Equatable {
    var id: String

    /// Free-form name for this amount, e.g. "1 slice". May be empty when a food has only one portion.
    var name: String

    /// Carbs in grams.
    var carbs: Double

    init(id: String = UUID().uuidString, name: String = "", carbs: Double) {
        self.id = id
        self.name = name
        self.carbs = carbs
    }

    var hasName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var carbsString: String {
        FavoriteFoodFormatters.carbs(carbs)
    }

    /// One line describing this amount, e.g. "Half a slice · 8 g".
    var summary: String {
        hasName ? "\(name) · \(carbsString)" : carbsString
    }
}

/// An optional, user-created group that favorite foods can be filed into.
///
/// Folders are purely an organizational overlay: a food's folder membership is stored on the food
/// itself, so a food whose folder is deleted simply becomes unfiled rather than being lost.
struct FavoriteFoodFolder: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    /// Optional emoji shown alongside the folder name.
    var emoji: String

    init(id: String = UUID().uuidString, name: String, emoji: String = "") {
        self.id = id
        self.name = name
        self.emoji = emoji
    }

    var title: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

/// A meal the user saved so it can be sent again without re-entering carbs, food type and
/// absorption time. Mirrors Loop's own Favorite Foods, but lives on this device.
struct StoredFavoriteFood: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    /// Emoji shown for the food. May be empty.
    var foodType: String
    /// Absorption time in seconds.
    var absorptionTime: TimeInterval
    /// Every amount this food can be sent at, in the order shown to the user. Never empty.
    var portions: [FavoriteFoodPortion]
    /// `id` of the `FavoriteFoodFolder` this food is filed under, or `nil` when unfiled.
    var folderID: String?

    /// When this food was last edited, on whichever device edited it. Drives last-writer-wins
    /// when the same food is changed in both Loop and LoopFollow between two syncs.
    var updatedAt: Date

    /// `_id` of the matching Nightscout food document, once the food has been synced.
    var nsID: String?

    init(id: String = UUID().uuidString, name: String, portions: [FavoriteFoodPortion], foodType: String, absorptionTime: TimeInterval, folderID: String? = nil, updatedAt: Date = Date(), nsID: String? = nil) {
        self.id = id
        self.name = name
        self.portions = portions.isEmpty ? [FavoriteFoodPortion(carbs: 0)] : portions
        self.foodType = foodType
        self.absorptionTime = absorptionTime
        self.folderID = folderID
        self.updatedAt = updatedAt
        self.nsID = nsID
    }

    /// Convenience for a food with a single amount.
    init(id: String = UUID().uuidString, name: String, carbs: Double, foodType: String, absorptionTime: TimeInterval, servingSize: String = "", folderID: String? = nil, updatedAt: Date = Date(), nsID: String? = nil) {
        self.init(
            id: id,
            name: name,
            portions: [FavoriteFoodPortion(name: servingSize, carbs: carbs)],
            foodType: foodType,
            absorptionTime: absorptionTime,
            folderID: folderID,
            updatedAt: updatedAt,
            nsID: nsID
        )
    }

    /// True when the two describe the same food to a user. The sync compares content rather than
    /// timestamps before writing, so an unchanged food is never pushed back and forth.
    func hasSameContent(as other: StoredFavoriteFood) -> Bool {
        id == other.id
            && name == other.name
            && foodType == other.foodType
            && absorptionTime == other.absorptionTime
            && portions == other.portions
            && folderID == other.folderID
    }

    /// The amount applied when the food is picked without choosing one — the first in the list.
    var defaultPortion: FavoriteFoodPortion {
        portions.first ?? FavoriteFoodPortion(carbs: 0)
    }

    var carbs: Double {
        defaultPortion.carbs
    }

    /// A food with several amounts has no single serving size, so this is empty for those.
    var servingSize: String {
        portions.count == 1 ? defaultPortion.name : ""
    }

    var hasServingSize: Bool {
        !servingSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when picking this food should also ask which amount is being eaten.
    var hasMultiplePortions: Bool {
        portions.count > 1
    }

    var title: String {
        foodType.isEmpty ? name : "\(name) \(foodType)"
    }

    var absorptionTimeString: String {
        FavoriteFoodFormatters.absorptionTime(absorptionTime)
    }

    /// "45 g carbs · 3 hr absorption", or the number of serving sizes for a multi-portion food.
    var summary: String {
        if hasMultiplePortions {
            return "\(portions.count) serving sizes · \(absorptionTimeString) absorption"
        }
        return "\(FavoriteFoodFormatters.carbs(carbs)) carbs · \(absorptionTimeString) absorption"
    }

    func portion(withID id: String?) -> FavoriteFoodPortion? {
        guard let id else { return nil }
        return portions.first(where: { $0.id == id })
    }

    /// Matches on the food's name, its serving sizes and emoji, so "skive" finds "Halv skive".
    func matches(searchQuery query: String) -> Bool {
        let haystack = [name, foodType] + portions.map(\.name)
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Decoding keeps working for foods written by an older build, which stored a single
    /// carb amount and serving size instead of a list of portions.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedPortions = try container.decodeIfPresent([FavoriteFoodPortion].self, forKey: .portions)
        let portions: [FavoriteFoodPortion]
        if let decodedPortions, !decodedPortions.isEmpty {
            portions = decodedPortions
        } else {
            portions = try [FavoriteFoodPortion(
                name: container.decodeIfPresent(String.self, forKey: .servingSize) ?? "",
                carbs: container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
            )]
        }

        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            portions: portions,
            foodType: container.decodeIfPresent(String.self, forKey: .foodType) ?? "",
            absorptionTime: container.decode(TimeInterval.self, forKey: .absorptionTime),
            folderID: container.decodeIfPresent(String.self, forKey: .folderID),
            // Foods stored before syncing existed count as old, so Nightscout's copy wins once.
            updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date.distantPast,
            nsID: container.decodeIfPresent(String.self, forKey: .nsID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(portions, forKey: .portions)
        try container.encode(foodType, forKey: .foodType)
        try container.encode(absorptionTime, forKey: .absorptionTime)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(nsID, forKey: .nsID)
        // Mirrored so a downgrade to a build without portions still reads a usable food.
        try container.encode(carbs, forKey: .carbs)
        try container.encode(servingSize, forKey: .servingSize)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case carbs
        case foodType
        case absorptionTime
        case servingSize
        case folderID
        case portions
        case updatedAt
        case nsID
    }
}

/// A favorite food that was deleted here, kept until the deletion has reached Nightscout.
///
/// A deletion travels as an edit carrying `deletedAt`, so the same last-writer-wins rule decides
/// between "deleted here" and "edited on the other device": the food only stays gone when nobody
/// has changed it since.
struct FavoriteFoodTombstone: Identifiable, Codable, Equatable {
    /// The favorite's stable id, shared with Loop.
    var id: String
    var nsID: String?
    var deletedAt: Date

    init(id: String, nsID: String?, deletedAt: Date = Date()) {
        self.id = id
        self.nsID = nsID
        self.deletedAt = deletedAt
    }
}

/// One group of favorite foods as shown in a list: either a user-created folder, or the
/// trailing group of foods that are not filed anywhere.
struct FavoriteFoodSection: Identifiable {
    static let unfiledID = "favoriteFoods.unfiled"

    let folder: FavoriteFoodFolder?
    let foods: [StoredFavoriteFood]

    var id: String { folder?.id ?? Self.unfiledID }
    var isUnfiled: Bool { folder == nil }
}

enum FavoriteFoodFormatters {
    static let carbFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 4
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func carbs(_ grams: Double) -> String {
        let number = carbFormatter.string(from: NSNumber(value: grams)) ?? "\(grams)"
        return "\(number) g"
    }

    static func absorptionTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(minutes) min"
        }
        if minutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(minutes) min"
    }
}

/// The absorption times a remote carb entry accepts. Favorites are edited within the same
/// limits and steps the carb screen sends with, so a saved food never has to be adjusted
/// before it can be sent.
enum FavoriteFoodAbsorption {
    static let minimum: TimeInterval = 30 * 60
    static let maximum: TimeInterval = 8 * 60 * 60
    static let step: TimeInterval = 30 * 60
    static let `default`: TimeInterval = 3 * 60 * 60

    static func clamped(_ absorptionTime: TimeInterval) -> TimeInterval {
        let stepped = (absorptionTime / step).rounded() * step
        return min(max(stepped, minimum), maximum)
    }

    /// Whole hours and remaining minutes, for the hour/minute pickers.
    static func components(_ absorptionTime: TimeInterval) -> (hours: Int, minutes: Int) {
        let totalMinutes = Int((clamped(absorptionTime) / 60).rounded())
        return (totalMinutes / 60, totalMinutes % 60)
    }

    static func timeInterval(hours: Int, minutes: Int) -> TimeInterval {
        clamped(TimeInterval(hours * 60 + minutes) * 60)
    }
}
