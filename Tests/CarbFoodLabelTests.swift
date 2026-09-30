// LoopFollow
// CarbFoodLabelTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The dish's name travels inside `foodType` between Loop, Nightscout and LoopFollow, and both
/// apps split it the same way. Loop's `LoopTests/Managers/CarbFoodLabelTests.swift` mirrors these
/// cases — change both.
struct CarbFoodLabelTests {
    @Test("emoji and name join with a space")
    func joins() {
        #expect(CarbFoodLabel(emoji: "🍕", name: "Pizza").foodType == "🍕 Pizza")
    }

    @Test("empty parts are left out")
    func emptyParts() {
        #expect(CarbFoodLabel(emoji: "🍕", name: " ").foodType == "🍕")
        #expect(CarbFoodLabel(emoji: "", name: "Pizza").foodType == "Pizza")
        #expect(CarbFoodLabel(emoji: "", name: "").foodType == nil)
    }

    @Test("splits the emoji from the name")
    func splits() {
        #expect(CarbFoodLabel(foodType: "🍕 Pizza") == CarbFoodLabel(emoji: "🍕", name: "Pizza"))
        #expect(CarbFoodLabel(foodType: "🍝 Pasta med kjøttsaus") == CarbFoodLabel(emoji: "🍝", name: "Pasta med kjøttsaus"))
    }

    @Test("an emoji alone has no name")
    func emojiOnly() {
        #expect(CarbFoodLabel(foodType: "🌮") == CarbFoodLabel(emoji: "🌮", name: ""))
        #expect(CarbFoodLabel(foodType: "🍽️") == CarbFoodLabel(emoji: "🍽️", name: ""))
    }

    @Test("several emoji stay together")
    func severalEmoji() {
        #expect(CarbFoodLabel(foodType: "🍔🍟 Burger og pommes") == CarbFoodLabel(emoji: "🍔🍟", name: "Burger og pommes"))
    }

    @Test("text without an emoji is all name")
    func textOnly() {
        #expect(CarbFoodLabel(foodType: "Simulated") == CarbFoodLabel(emoji: "", name: "Simulated"))
        #expect(CarbFoodLabel(foodType: "2 brødskiver") == CarbFoodLabel(emoji: "", name: "2 brødskiver"))
    }

    @Test("a missing food type is empty")
    func missing() {
        #expect(CarbFoodLabel(foodType: nil) == CarbFoodLabel(emoji: "", name: ""))
    }

    @Test("round trips", arguments: ["🍕 Pizza", "🌮", "Pasta", "🍔🍟 Burger og pommes"])
    func roundTrips(foodType: String) {
        #expect(CarbFoodLabel(foodType: foodType).foodType == foodType)
    }

    @Test("chart pill shows the emoji and the name")
    func chartPill() {
        #expect(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: "🍕 Pizza"), grams: 30, time: "12:30") == "Carbs 🍕\nPizza\n30g\n12:30")
        #expect(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: "🌮"), grams: 30, time: "12:30") == "Carbs 🌮\n30g\n12:30")
        #expect(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: nil), grams: 30, time: "12:30") == "Carbs\n30g\n12:30")
    }
}
