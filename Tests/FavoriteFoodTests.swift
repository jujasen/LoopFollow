// LoopFollow
// FavoriteFoodTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Favorite foods are edited by hand and then sent as carbs, so the parts that decide what
/// gets sent — which portion is the default, what a stored food decodes back into, and how an
/// absorption time is snapped to what the carb screen accepts — are pinned here.
struct FavoriteFoodTests {
    private static func bread(folderID: String? = nil) -> StoredFavoriteFood {
        StoredFavoriteFood(
            id: "bread",
            name: "Brødskive",
            portions: [
                FavoriteFoodPortion(id: "whole", name: "1 skive", carbs: 16),
                FavoriteFoodPortion(id: "half", name: "Halv skive", carbs: 8),
            ],
            foodType: "🍞",
            absorptionTime: 3 * 3600,
            folderID: folderID
        )
    }

    private static func apple(folderID: String? = nil) -> StoredFavoriteFood {
        StoredFavoriteFood(id: "apple", name: "Eple", carbs: 14, foodType: "🍎", absorptionTime: 2 * 3600, servingSize: "1 stk", folderID: folderID)
    }

    // MARK: - The food itself

    @Test func firstPortionIsTheOneSentOnASingleTap() {
        let food = Self.bread()
        #expect(food.defaultPortion.id == "whole")
        #expect(food.carbs == 16)
        #expect(food.hasMultiplePortions)
        // Several amounts means there is no single serving size to show.
        #expect(food.servingSize.isEmpty)
        #expect(food.portion(withID: "half")?.carbs == 8)
        #expect(food.portion(withID: "missing") == nil)
    }

    @Test func singlePortionFoodKeepsItsServingSize() {
        let food = Self.apple()
        #expect(!food.hasMultiplePortions)
        #expect(food.servingSize == "1 stk")
        #expect(food.hasServingSize)
        #expect(food.carbs == 14)
    }

    @Test func aFoodWithNoPortionsStillHasOne() {
        let food = StoredFavoriteFood(id: "x", name: "Tom", portions: [], foodType: "", absorptionTime: 3600)
        #expect(food.portions.count == 1)
        #expect(food.carbs == 0)
    }

    @Test func searchMatchesNameServingSizeAndEmoji() {
        let food = Self.bread()
        #expect(food.matches(searchQuery: "brød"))
        #expect(food.matches(searchQuery: "halv"))
        #expect(food.matches(searchQuery: "🍞"))
        #expect(!food.matches(searchQuery: "pizza"))
    }

    // MARK: - Storage

    @Test func codableRoundTripKeepsEveryPortion() throws {
        let food = Self.bread(folderID: "breakfast")
        let data = try JSONEncoder().encode(food)
        let decoded = try JSONDecoder().decode(StoredFavoriteFood.self, from: data)

        #expect(decoded == food)
        #expect(decoded.portions.map(\.name) == ["1 skive", "Halv skive"])
        #expect(decoded.folderID == "breakfast")
    }

    /// A food written before portions existed carries one carb amount and a serving size.
    @Test func decodingAPrePortionFoodProducesOnePortion() throws {
        let legacy = """
        {"id":"legacy","name":"Yoghurt","carbs":22.5,"foodType":"🥣","absorptionTime":7200,"servingSize":"1 beger"}
        """
        let decoded = try JSONDecoder().decode(StoredFavoriteFood.self, from: Data(legacy.utf8))

        #expect(decoded.portions.count == 1)
        #expect(decoded.carbs == 22.5)
        #expect(decoded.servingSize == "1 beger")
        #expect(decoded.absorptionTime == 7200)
    }

    /// The encoder mirrors the default amount into the old keys, so an older build reading the
    /// same store still finds a usable food.
    @Test func encodingMirrorsTheDefaultAmountIntoTheLegacyKeys() throws {
        let data = try JSONEncoder().encode(Self.bread())
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["carbs"] as? Double == 16)
        #expect(json?["servingSize"] as? String == "")
    }

    // MARK: - Absorption time

    @Test func absorptionTimeIsSnappedToWhatTheCarbScreenAccepts() {
        // Below the minimum, above the maximum, and between two steps.
        #expect(FavoriteFoodAbsorption.clamped(5 * 60) == 30 * 60)
        #expect(FavoriteFoodAbsorption.clamped(12 * 3600) == 8 * 3600)
        #expect(FavoriteFoodAbsorption.clamped(70 * 60) == 60 * 60)
        #expect(FavoriteFoodAbsorption.clamped(80 * 60) == 90 * 60)
    }

    @Test func absorptionComponentsRoundTrip() {
        let components = FavoriteFoodAbsorption.components(2.5 * 3600)
        #expect(components.hours == 2)
        #expect(components.minutes == 30)
        #expect(FavoriteFoodAbsorption.timeInterval(hours: 2, minutes: 30) == 2.5 * 3600)
        // Out-of-range picks are pulled back into range rather than sent as-is.
        #expect(FavoriteFoodAbsorption.timeInterval(hours: 0, minutes: 0) == FavoriteFoodAbsorption.minimum)
        #expect(FavoriteFoodAbsorption.timeInterval(hours: 9, minutes: 30) == FavoriteFoodAbsorption.maximum)
    }

    // MARK: - Grouping

    @Test func foodsAreGroupedByFolderWithUnfiledLast() {
        let breakfast = FavoriteFoodFolder(id: "breakfast", name: "Frokost", emoji: "🥣")
        let sections = FavoriteFoodsStore.sections(
            foods: [Self.bread(folderID: "breakfast"), Self.apple()],
            folders: [breakfast]
        )

        #expect(sections.count == 2)
        #expect(sections[0].folder?.id == "breakfast")
        #expect(sections[0].foods.map(\.id) == ["bread"])
        #expect(sections[1].isUnfiled)
        #expect(sections[1].foods.map(\.id) == ["apple"])
    }

    /// A food pointing at a folder that was deleted is shown, not lost.
    @Test func foodInAMissingFolderFallsBackToUnfiled() {
        let sections = FavoriteFoodsStore.sections(foods: [Self.bread(folderID: "gone")], folders: [])

        #expect(sections.count == 1)
        #expect(sections[0].isUnfiled)
        #expect(sections[0].foods.map(\.id) == ["bread"])
    }

    @Test func emptyFoldersAreKeptWhileEditingAndDroppedWhilePicking() {
        let folders = [FavoriteFoodFolder(id: "breakfast", name: "Frokost")]

        let editing = FavoriteFoodsStore.sections(foods: [Self.apple()], folders: folders)
        #expect(editing.map(\.id) == ["breakfast", FavoriteFoodSection.unfiledID])

        let picking = FavoriteFoodsStore.sections(foods: [Self.apple()], folders: folders, includeEmptySections: false)
        #expect(picking.map(\.id) == [FavoriteFoodSection.unfiledID])
    }

    @Test func searchNarrowsTheSections() {
        let folders = [FavoriteFoodFolder(id: "breakfast", name: "Frokost")]
        let sections = FavoriteFoodsStore.sections(
            foods: [Self.bread(folderID: "breakfast"), Self.apple()],
            folders: folders,
            searchQuery: "eple"
        )

        #expect(sections.flatMap(\.foods).map(\.id) == ["apple"])
    }

    /// A move inside one folder must not disturb the foods filed elsewhere.
    @Test func reorderingInsideAFolderLeavesOtherFoodsAlone() {
        let folders = [FavoriteFoodFolder(id: "breakfast", name: "Frokost")]
        let pizza = StoredFavoriteFood(id: "pizza", name: "Pizza", carbs: 60, foodType: "🍕", absorptionTime: 5 * 3600, folderID: "breakfast")
        let foods = [Self.bread(folderID: "breakfast"), Self.apple(), pizza]
        let section = FavoriteFoodSection(folder: folders[0], foods: [foods[0], pizza])

        let reordered = FavoriteFoodsStore.reordered(foods: foods, folders: folders, in: section, from: IndexSet(integer: 1), to: 0)

        #expect(reordered.map(\.id) == ["pizza", "apple", "bread"])
    }
}
