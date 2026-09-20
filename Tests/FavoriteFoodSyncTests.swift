// LoopFollow
// FavoriteFoodSyncTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Favorites are edited on two phones that only meet through Nightscout, so the rules that
/// decide which side wins — and that a deletion stays deleted without eating a concurrent edit —
/// are pinned here. Loop runs the same rules on its copy.
struct FavoriteFoodSyncTests {
    private static let now = Date(timeIntervalSince1970: 1_758_000_000)

    private static func food(
        id: String = "bread",
        name: String = "Brødskive",
        carbs: Double = 16,
        foodType: String = "🍞",
        absorptionTime: TimeInterval = 3 * 3600,
        folderID: String? = nil,
        updatedAt: Date,
        nsID: String? = nil
    ) -> StoredFavoriteFood {
        StoredFavoriteFood(
            id: id,
            name: name,
            carbs: carbs,
            foodType: foodType,
            absorptionTime: absorptionTime,
            folderID: folderID,
            updatedAt: updatedAt,
            nsID: nsID
        )
    }

    /// A Nightscout document as the other app would have written it.
    private static func remote(
        _ food: StoredFavoriteFood,
        nsID: String = "aaaaaaaaaaaaaaaaaaaaaaaa",
        folder: FavoriteFoodFolder? = nil,
        deletedAt: Date? = nil
    ) -> FavoriteFoodSyncDocument.Parsed {
        var document = FavoriteFoodSyncDocument.document(for: food, folder: folder, deletedAt: deletedAt)
        document["_id"] = nsID
        let parsed = FavoriteFoodSyncDocument.parse(document)
        #expect(parsed != nil)
        return parsed!
    }

    private static func merge(
        foods: [StoredFavoriteFood] = [],
        folders: [FavoriteFoodFolder] = [],
        tombstones: [FavoriteFoodTombstone] = [],
        remote: [FavoriteFoodSyncDocument.Parsed] = [],
        remoteIsComplete: Bool = true
    ) -> FavoriteFoodSyncEngine.Outcome {
        FavoriteFoodSyncEngine.merge(
            .init(
                foods: foods,
                folders: folders,
                tombstones: tombstones,
                remote: remote,
                remoteIsComplete: remoteIsComplete,
                now: now
            )
        )
    }

    // MARK: - The shared document

    @Test func documentSurvivesARoundTrip() {
        let folder = FavoriteFoodFolder(id: "f1", name: "Frokost", emoji: "🥣")
        let original = StoredFavoriteFood(
            id: "bread",
            name: "Brødskive",
            portions: [
                FavoriteFoodPortion(id: "whole", name: "1 skive", carbs: 16),
                FavoriteFoodPortion(id: "half", name: "Halv skive", carbs: 8),
            ],
            foodType: "🍞",
            absorptionTime: 2.5 * 3600,
            folderID: folder.id,
            updatedAt: Self.now
        )

        let parsed = Self.remote(original, folder: folder)

        #expect(parsed.food.id == original.id)
        #expect(parsed.food.name == original.name)
        #expect(parsed.food.foodType == "🍞")
        #expect(parsed.food.absorptionTime == 2.5 * 3600)
        #expect(parsed.food.portions == original.portions)
        #expect(parsed.food.folderID == folder.id)
        #expect(parsed.folder == folder)
        #expect(!parsed.isAdopted)
        // Timestamps travel as milliseconds, so they come back to the millisecond.
        #expect(abs(parsed.food.updatedAt.timeIntervalSince(Self.now)) < 0.001)
    }

    /// The document also reads as an ordinary Nightscout food entry, so the food editor on the
    /// site shows something sensible.
    @Test func documentLooksLikeAPlainNightscoutFood() {
        let food = StoredFavoriteFood(id: "yog", name: "Yoghurt", carbs: 22, foodType: "🥣", absorptionTime: 7200, servingSize: "1 beger")
        let document = FavoriteFoodSyncDocument.document(for: food, folder: FavoriteFoodFolder(id: "f1", name: "Frokost"))

        #expect(document["type"] as? String == "food")
        #expect(document["name"] as? String == "Yoghurt")
        #expect(document["carbs"] as? Double == 22)
        #expect(document["category"] as? String == "Frokost")
        #expect(document["unit"] as? String == "1 beger")
    }

    /// A food someone typed into Nightscout's own food editor is taken over rather than ignored.
    @Test func plainNightscoutFoodIsAdopted() {
        let parsed = FavoriteFoodSyncDocument.parse([
            "_id": "bbbbbbbbbbbbbbbbbbbbbbbb",
            "type": "food",
            "name": "Banan",
            "carbs": 25,
            "category": "Mellommåltid",
            "unit": "1 stk",
        ])

        #expect(parsed?.isAdopted == true)
        #expect(parsed?.food.name == "Banan")
        #expect(parsed?.food.carbs == 25)
        #expect(parsed?.food.servingSize == "1 stk")
        #expect(parsed?.food.absorptionTime == FavoriteFoodAbsorption.default)
        // Its id comes from the document, so both apps adopt it as the same favorite.
        #expect(parsed?.food.id == "bbbbbbbbbbbbbbbbbbbbbbbb")
        // And it never outranks a real edit.
        #expect(parsed?.food.updatedAt == Date.distantPast)
    }

    // MARK: - Merging

    @Test func aFoodOnlyThisPhoneHasIsCreatedInNightscout() {
        let local = Self.food(updatedAt: Self.now)
        let outcome = Self.merge(foods: [local])

        #expect(outcome.foods.map(\.id) == ["bread"])
        #expect(outcome.creates.map(\.id) == ["bread"])
        #expect(outcome.updates.isEmpty)
    }

    @Test func aFoodOnlyNightscoutHasIsAddedHere() {
        let folder = FavoriteFoodFolder(id: "f1", name: "Frokost", emoji: "🥣")
        let incoming = Self.food(updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = Self.merge(remote: [Self.remote(incoming, folder: folder)])

        #expect(outcome.foods.map(\.id) == ["bread"])
        #expect(outcome.foods.first?.nsID == "aaaaaaaaaaaaaaaaaaaaaaaa")
        // The folder it was filed in comes along with it.
        #expect(outcome.folders == [folder])
        #expect(outcome.creates.isEmpty)
    }

    @Test func theNewerEditWins() {
        let older = Self.food(name: "Gammel", updatedAt: Self.now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let newer = Self.food(name: "Ny", updatedAt: Self.now)

        let remoteWins = Self.merge(foods: [older], remote: [Self.remote(newer)])
        #expect(remoteWins.foods.first?.name == "Ny")
        #expect(remoteWins.updates.isEmpty)

        let localWins = Self.merge(foods: [Self.food(name: "Ny", updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")], remote: [Self.remote(older)])
        #expect(localWins.foods.first?.name == "Ny")
        #expect(localWins.updates.map(\.name) == ["Ny"])
    }

    /// The same food on both sides, unchanged, must not be written back — otherwise the two apps
    /// would keep handing the same food to each other forever.
    @Test func anUnchangedFoodIsNotPushedBack() {
        let food = Self.food(updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = Self.merge(foods: [food], remote: [Self.remote(food)])

        #expect(outcome.updates.isEmpty)
        #expect(outcome.creates.isEmpty)
        #expect(outcome.foods == [food])
    }

    @Test func aFoodDeletedElsewhereDisappearsHere() {
        let local = Self.food(updatedAt: Self.now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = Self.merge(
            foods: [local],
            remote: [Self.remote(local, deletedAt: Self.now)]
        )

        #expect(outcome.foods.isEmpty)
        #expect(outcome.updates.isEmpty)
    }

    /// Deleting here while the other phone edited the same food afterwards: the edit wins, and
    /// the food comes back rather than being silently lost.
    @Test func anEditAfterADeleteBringsTheFoodBack() {
        let edited = Self.food(name: "Endret i Loop", updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let tombstone = FavoriteFoodTombstone(id: "bread", nsID: "aaaaaaaaaaaaaaaaaaaaaaaa", deletedAt: Self.now.addingTimeInterval(-600))

        let outcome = Self.merge(tombstones: [tombstone], remote: [Self.remote(edited)])

        #expect(outcome.foods.map(\.name) == ["Endret i Loop"])
        #expect(outcome.tombstones.isEmpty)
        #expect(outcome.deletions.isEmpty)
    }

    @Test func aDeletionHereIsPushedToNightscout() {
        let food = Self.food(updatedAt: Self.now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let tombstone = FavoriteFoodTombstone(id: "bread", nsID: "aaaaaaaaaaaaaaaaaaaaaaaa", deletedAt: Self.now)

        let outcome = Self.merge(tombstones: [tombstone], remote: [Self.remote(food)])

        #expect(outcome.foods.isEmpty)
        #expect(outcome.deletions.map(\.id) == ["bread"])
        // Kept until the push has gone through; the service drops it afterwards.
        #expect(outcome.tombstones.map(\.id) == ["bread"])
    }

    @Test func aTombstoneForAFoodNightscoutNoLongerHasIsDropped() {
        let tombstone = FavoriteFoodTombstone(id: "bread", nsID: "aaaaaaaaaaaaaaaaaaaaaaaa", deletedAt: Self.now)
        let outcome = Self.merge(tombstones: [tombstone])

        #expect(outcome.tombstones.isEmpty)
        #expect(outcome.deletions.isEmpty)
    }

    @Test func aLongDeadDocumentIsRemovedForGood() {
        let food = Self.food(updatedAt: Self.now.addingTimeInterval(-90 * 24 * 3600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let deletedLongAgo = Self.now.addingTimeInterval(-60 * 24 * 3600)

        let outcome = Self.merge(remote: [Self.remote(food, deletedAt: deletedLongAgo)])

        #expect(outcome.purges == ["aaaaaaaaaaaaaaaaaaaaaaaa"])
        #expect(outcome.foods.isEmpty)
    }

    /// A food that was synced once and is gone from Nightscout was removed by someone else.
    @Test func aSyncedFoodMissingFromNightscoutIsDroppedHere() {
        let stillThere = Self.food(id: "other", name: "Annet", updatedAt: Self.now, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb")
        let removedElsewhere = Self.food(updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")

        let outcome = Self.merge(
            foods: [removedElsewhere, stillThere],
            remote: [Self.remote(stillThere, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb")]
        )

        #expect(outcome.foods.map(\.id) == ["other"])
        #expect(outcome.creates.isEmpty)
    }

    /// …but an empty food collection is a wiped or unreadable site, not a mass deletion. The
    /// foods here are kept and pushed back rather than thrown away.
    @Test func anEmptyFoodCollectionNeverEmptiesThisPhone() {
        let local = Self.food(updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = Self.merge(foods: [local])

        #expect(outcome.foods.map(\.id) == ["bread"])
        #expect(outcome.creates.map(\.id) == ["bread"])
    }

    /// …but not when the listing may have been cut short.
    @Test func nothingIsDroppedFromAnIncompleteListing() {
        let local = Self.food(updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = Self.merge(foods: [local], remoteIsComplete: false)

        #expect(outcome.foods.map(\.id) == ["bread"])
    }

    /// Order is this phone's own business, so foods already here keep their places and anything
    /// new from Nightscout is appended.
    @Test func localOrderIsKept() {
        let first = Self.food(id: "a", name: "A", updatedAt: Self.now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let second = Self.food(id: "b", name: "B", updatedAt: Self.now, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb")
        let incoming = Self.food(id: "c", name: "C", updatedAt: Self.now, nsID: "cccccccccccccccccccccccc")

        let outcome = Self.merge(
            foods: [first, second],
            remote: [
                Self.remote(second, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb"),
                Self.remote(incoming, nsID: "cccccccccccccccccccccccc"),
                Self.remote(first, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa"),
            ]
        )

        #expect(outcome.foods.map(\.id) == ["a", "b", "c"])
    }
}
