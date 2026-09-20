// LoopFollow
// FavoriteFoodNightscoutSync.swift

import Foundation

/// Favorite foods are shared with Loop through Nightscout's `food` collection: both apps keep
/// their own copy, and one document per food carries the shared truth.
///
/// A document looks like an ordinary Nightscout food entry — so it stays readable in
/// Nightscout's own food editor — with everything the two apps need in a `loopFavorite` block:
///
/// ```json
/// { "_id": "…", "type": "food", "name": "Brødskive", "category": "Frokost",
///   "carbs": 16, "portion": 1, "unit": "1 skive",
///   "loopFavorite": { "id": "…", "foodType": "🍞", "absorptionTime": 10800,
///                     "portions": [{"id":"…","name":"1 skive","carbs":16}],
///                     "folder": {"id":"…","name":"Frokost","emoji":"🥣"},
///                     "updatedAt": 1758364800000, "deletedAt": null } }
/// ```
///
/// `updatedAt` decides who wins when the same food was changed in both apps between two syncs,
/// and a deletion is an edit carrying `deletedAt` rather than a removed document, so a delete
/// and a concurrent edit are resolved by the same rule.
enum FavoriteFoodSyncDocument {
    static let blockKey = "loopFavorite"

    /// How long a deleted food stays in Nightscout before it is removed for good. Long enough
    /// that a phone that was off the whole time still learns about the deletion.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    struct Parsed {
        var nsID: String
        var food: StoredFavoriteFood
        var folder: FavoriteFoodFolder?
        var deletedAt: Date?
        /// True when the document had no `loopFavorite` block — a plain food entry made in
        /// Nightscout's food editor, which we take over on the next write.
        var isAdopted: Bool
        /// The document as Nightscout stores it, so writing back keeps fields we don't model.
        var raw: [String: Any]
    }

    // MARK: - Reading

    static func parse(_ raw: [String: Any]) -> Parsed? {
        guard let nsID = raw["_id"] as? String, !nsID.isEmpty else { return nil }

        if let block = raw[blockKey] as? [String: Any] {
            return parse(block: block, nsID: nsID, raw: raw)
        }

        return adopt(raw, nsID: nsID)
    }

    private static func parse(block: [String: Any], nsID: String, raw: [String: Any]) -> Parsed? {
        guard let id = block["id"] as? String, !id.isEmpty else { return nil }

        let name = (raw["name"] as? String) ?? (block["name"] as? String) ?? ""
        let portions = (block["portions"] as? [[String: Any]])?.compactMap(portion(from:)) ?? []
        let folder = folder(from: block["folder"] as? [String: Any])

        let food = StoredFavoriteFood(
            id: id,
            name: name,
            portions: portions.isEmpty ? [FavoriteFoodPortion(carbs: number(raw["carbs"]) ?? 0)] : portions,
            foodType: (block["foodType"] as? String) ?? "",
            absorptionTime: number(block["absorptionTime"]) ?? FavoriteFoodAbsorption.default,
            folderID: folder?.id,
            updatedAt: date(from: block["updatedAt"]) ?? Date.distantPast,
            nsID: nsID
        )

        return Parsed(
            nsID: nsID,
            food: food,
            folder: folder,
            deletedAt: date(from: block["deletedAt"]),
            isAdopted: false,
            raw: raw
        )
    }

    /// Turns a plain Nightscout food entry into a favorite. Its id is derived from the
    /// document id, so both apps adopt the same entry as the same favorite.
    private static func adopt(_ raw: [String: Any], nsID: String) -> Parsed? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        guard let carbs = number(raw["carbs"]) else { return nil }

        let category = (raw["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = category.isEmpty ? nil : FavoriteFoodFolder(id: "ns-category-\(category)", name: category)

        let food = StoredFavoriteFood(
            id: nsID,
            name: name,
            carbs: carbs,
            foodType: "",
            absorptionTime: FavoriteFoodAbsorption.default,
            servingSize: (raw["unit"] as? String) ?? "",
            folderID: folder?.id,
            // Never newer than an edit made in either app, so adopting can't overwrite one.
            updatedAt: Date.distantPast,
            nsID: nsID
        )

        return Parsed(nsID: nsID, food: food, folder: folder, deletedAt: nil, isAdopted: true, raw: raw)
    }

    private static func portion(from raw: [String: Any]) -> FavoriteFoodPortion? {
        guard let carbs = number(raw["carbs"]) else { return nil }
        return FavoriteFoodPortion(
            id: (raw["id"] as? String) ?? UUID().uuidString,
            name: (raw["name"] as? String) ?? "",
            carbs: carbs
        )
    }

    private static func folder(from raw: [String: Any]?) -> FavoriteFoodFolder? {
        guard let raw, let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        return FavoriteFoodFolder(id: id, name: name, emoji: (raw["emoji"] as? String) ?? "")
    }

    // MARK: - Writing

    /// Builds the document to send for `food`. Starting from the stored document keeps any
    /// fields Nightscout or its food editor added that we don't model.
    static func document(for food: StoredFavoriteFood, folder: FavoriteFoodFolder?, deletedAt: Date? = nil, base: [String: Any]? = nil) -> [String: Any] {
        var document = base ?? [:]

        document["type"] = "food"
        document["name"] = food.name
        document["category"] = folder?.name ?? ""
        if document["subcategory"] == nil { document["subcategory"] = "" }
        document["carbs"] = food.carbs
        document["portion"] = 1
        document["unit"] = food.defaultPortion.hasName ? food.defaultPortion.name : "portion"

        var block: [String: Any] = [
            "id": food.id,
            "foodType": food.foodType,
            "absorptionTime": food.absorptionTime,
            "portions": food.portions.map { ["id": $0.id, "name": $0.name, "carbs": $0.carbs] },
            "updatedAt": milliseconds(from: max(food.updatedAt, deletedAt ?? food.updatedAt)),
        ]

        if let folder {
            block["folder"] = ["id": folder.id, "name": folder.name, "emoji": folder.emoji]
        }

        if let deletedAt {
            block["deletedAt"] = milliseconds(from: deletedAt)
        }

        document[blockKey] = block

        if let nsID = food.nsID, document["_id"] == nil {
            document["_id"] = nsID
        }

        return document
    }

    // MARK: - Helpers

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        guard let milliseconds = number(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func milliseconds(from date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }
}

/// Decides, per food, which side is newer — without touching storage or the network, so the
/// rules can be tested on their own. Loop runs the same rules on its copy.
enum FavoriteFoodSyncEngine {
    struct Outcome: Equatable {
        /// What the local store should hold afterwards.
        var foods: [StoredFavoriteFood] = []
        var folders: [FavoriteFoodFolder] = []
        var tombstones: [FavoriteFoodTombstone] = []

        /// Foods to POST as new Nightscout documents.
        var creates: [StoredFavoriteFood] = []
        /// Foods to PUT, by document id.
        var updates: [StoredFavoriteFood] = []
        /// Foods to PUT carrying a `deletedAt`.
        var deletions: [FavoriteFoodTombstone] = []
        /// Documents whose deletion is old enough to remove for good.
        var purges: [String] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.foods == rhs.foods
                && lhs.folders == rhs.folders
                && lhs.tombstones == rhs.tombstones
                && lhs.creates == rhs.creates
                && lhs.updates == rhs.updates
                && lhs.deletions == rhs.deletions
                && lhs.purges == rhs.purges
        }
    }

    struct Input {
        var foods: [StoredFavoriteFood]
        var folders: [FavoriteFoodFolder]
        var tombstones: [FavoriteFoodTombstone]
        var remote: [FavoriteFoodSyncDocument.Parsed]
        /// False when the fetch may have been cut short. A food missing from a partial listing
        /// says nothing about whether it still exists, so nothing is removed locally.
        var remoteIsComplete: Bool
        var now: Date
    }

    static func merge(_ input: Input) -> Outcome {
        var outcome = Outcome()
        outcome.folders = input.folders

        var remoteByID: [String: FavoriteFoodSyncDocument.Parsed] = [:]
        for parsed in input.remote {
            // A document edited later wins if the same favorite somehow exists twice.
            if let existing = remoteByID[parsed.food.id], existing.food.updatedAt > parsed.food.updatedAt {
                continue
            }
            remoteByID[parsed.food.id] = parsed
        }

        var handledRemoteIDs = Set<String>()
        var tombstoneByID: [String: FavoriteFoodTombstone] = [:]
        for tombstone in input.tombstones {
            tombstoneByID[tombstone.id] = tombstone
        }

        // An empty listing is never taken as "everything was deleted": a wiped or unreadable
        // food collection would otherwise empty this phone's list too. With nothing to compare
        // against, the foods here are pushed back instead.
        let remoteHasAnything = !remoteByID.isEmpty

        // 1. Foods we hold locally.
        for local in input.foods {
            guard let remote = remoteByID[local.id] else {
                if local.nsID != nil, input.remoteIsComplete, remoteHasAnything {
                    // It was synced once and is gone from Nightscout now: someone removed it
                    // for good elsewhere.
                    continue
                }
                outcome.foods.append(local)
                outcome.creates.append(local)
                continue
            }

            handledRemoteIDs.insert(local.id)

            if let deletedAt = remote.deletedAt, deletedAt >= local.updatedAt {
                // Deleted on the other side, and not changed here since.
                continue
            }

            if remote.food.updatedAt > local.updatedAt {
                outcome.foods.append(remote.food)
                adopt(folder: remote.folder, into: &outcome.folders)
            } else {
                var merged = local
                merged.nsID = remote.nsID
                outcome.foods.append(merged)

                let folder = outcome.folders.first(where: { $0.id == merged.folderID })
                if remote.isAdopted || remote.deletedAt != nil || !remote.food.hasSameContent(as: merged) || folderDiffers(remote: remote.folder, local: folder) {
                    outcome.updates.append(merged)
                }
            }
        }

        // 2. Foods only Nightscout knows about.
        for (id, remote) in remoteByID where !handledRemoteIDs.contains(id) {
            if let deletedAt = remote.deletedAt {
                if input.now.timeIntervalSince(deletedAt) > FavoriteFoodSyncDocument.tombstoneLifetime {
                    outcome.purges.append(remote.nsID)
                }
                tombstoneByID[id] = nil
                continue
            }

            if let tombstone = tombstoneByID[id] {
                if tombstone.deletedAt >= remote.food.updatedAt {
                    // Deleted here, and untouched elsewhere since: push the deletion.
                    var pending = tombstone
                    pending.nsID = remote.nsID
                    outcome.deletions.append(pending)
                    tombstoneByID[id] = pending
                    continue
                }
                // Changed on the other side after we deleted it, so the change wins.
                tombstoneByID[id] = nil
            }

            outcome.foods.append(remote.food)
            adopt(folder: remote.folder, into: &outcome.folders)
        }

        // 3. Deletions of foods Nightscout no longer lists: nothing left to tell it about.
        for tombstone in tombstoneByID.values {
            guard remoteByID[tombstone.id] != nil else {
                tombstoneByID[tombstone.id] = nil
                continue
            }
        }

        outcome.tombstones = tombstoneByID.values
            .filter { input.now.timeIntervalSince($0.deletedAt) <= FavoriteFoodSyncDocument.tombstoneLifetime }
            .sorted { $0.deletedAt < $1.deletedAt }

        // Keep the local order stable: foods already known here keep their position, new ones
        // from Nightscout land at the end.
        outcome.foods = ordered(outcome.foods, like: input.foods)
        outcome.folders = outcome.folders.filter { folder in
            outcome.foods.contains(where: { $0.folderID == folder.id }) || input.folders.contains(where: { $0.id == folder.id })
        }

        return outcome
    }

    private static func adopt(folder: FavoriteFoodFolder?, into folders: inout [FavoriteFoodFolder]) {
        guard let folder else { return }
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }
    }

    private static func folderDiffers(remote: FavoriteFoodFolder?, local: FavoriteFoodFolder?) -> Bool {
        switch (remote, local) {
        case (nil, nil): return false
        case let (remote?, local?): return remote != local
        default: return true
        }
    }

    private static func ordered(_ foods: [StoredFavoriteFood], like original: [StoredFavoriteFood]) -> [StoredFavoriteFood] {
        let positions = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element.id, $0.offset) })
        return foods.enumerated().sorted { lhs, rhs in
            let left = positions[lhs.element.id]
            let right = positions[rhs.element.id]
            switch (left, right) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
