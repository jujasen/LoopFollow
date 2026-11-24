// LoopFollow
// InsightMealFavoritesTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The deeper insight from Loop, the meal estimate that may search the web, and the favorites
/// shown on the carb screen.
struct InsightMealFavoritesTests {
    // MARK: Insight

    private static let document: [String: Any] = [
        "_id": LoopInsightDocument.id,
        "type": "loopInsight", "version": 1, "uploadedAt": "2026-11-19T08:05:00Z", "aiEnabled": true,
        "aiUsageToday": ["calls": 3, "dollars": 0.05],
        "created_at": "2026-01-01T00:00:00.000Z",
        "insight": [
            "longTerm": [
                "days": 30, "dayparts": [[String: Any]](), "averageDailyCarbsGrams": 140, "averageDailyBolusUnits": 6.2,
                "meals": [Any](), "advice": [Any](), "computedAt": "2026-11-19T08:00:00Z",
                "recentDays": [["date": "2026-11-18T00:00:00Z", "timeInRangePercent": 55, "meanMmol": 9.8, "lowEpisodes": 0, "hoursAboveTen": 8.5, "carbsGrams": 150, "bolusUnits": 5, "automaticUnits": 3]],
                "weeks": [["end": "2026-11-19T08:00:00Z", "period": ["meanMmol": 8.4, "timeInRangePercent": 66, "belowRangePercent": 2, "aboveRangePercent": 32, "lowEpisodes": 2, "readings": 2000], "carbsGramsPerDay": 140, "bolusUnitsPerDay": 6]],
            ],
            "todayText": ["summary": "Høy dag.", "points": [String](), "dose_hints": [String](), "created_at": "2026-11-19T08:00:00Z",
                          "causes": ["Frokost uten bolus."], "fixes": ["Gi frokostbolus før maten."]],
            "longTermText": ["summary": "Kveldene er høye.", "points": [String](), "dose_hints": [String](), "created_at": "2026-11-19T04:10:00Z",
                             "trend": "Opp fra 60 til 66 % på fire uker.", "fixes": ["Middagsbolus 15 min før maten."],
                             "suggestions": [
                                 ["setting": "insulin_sensitivity", "daypart": "ettermiddag 15-19", "startHour": 15, "endHour": 19, "current": 18, "proposed": 16, "reason": "Høy 4 dager.", "evidenceDays": 4, "state": "done"],
                                 ["setting": "carb_ratio", "daypart": "kveld 19-24", "startHour": 19, "endHour": 24, "current": 15, "proposed": 13.5, "reason": "Høy 3 dager.", "evidenceDays": 3, "state": "changed"],
                             ]],
        ],
    ]

    @Test("causes, fixes, trend, days, weeks and how suggestions stand are read")
    func readsTheDeeperInsight() throws {
        let found = try #require(LoopInsightDocument.find(in: [Self.document]))
        #expect(found.insight.todayText?.causes == ["Frokost uten bolus."])
        #expect(found.insight.todayText?.fixes == ["Gi frokostbolus før maten."])
        #expect(found.insight.longTermText?.trend == "Opp fra 60 til 66 % på fire uker.")
        #expect(found.insight.longTerm?.recentDays?.first?.timeInRangePercent == 55)
        #expect(found.insight.longTerm?.weeks?.first?.period.timeInRangePercent == 66)
        let suggestions = try #require(found.insight.longTermText?.suggestions)
        #expect(suggestions[0].isDone)
        #expect(suggestions[1].isStale)
    }

    // MARK: Meal estimate

    private static let estimateJSON = #"{"name":"Yoghurt","emoji":"🥛","carbs_grams":10.8,"absorption_hours":2,"absorption_reason":"2 t: melkeprodukt med sukker.","items":[{"food":"Tine Yoghurt Junior","amount":"1 pose","carbs_grams":10.8}],"assumptions":["Tine.no: 10,8 g per pose"],"confidence":"high","fat_grams":2.5,"protein_grams":3}"#

    private static func response(_ blocks: [[String: Any]], stop: String = "end_turn") -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": blocks, "stop_reason": stop])
    }

    @Test("an answer after a web search is read from the text around it")
    func readsAnAnswerAfterASearch() throws {
        let data = Self.response([
            ["type": "server_tool_use", "id": "s1", "name": "web_search"],
            ["type": "web_search_tool_result", "tool_use_id": "s1", "content": [Any]()],
            ["type": "text", "text": "Tine oppgir 10,8 g karbo per pose.\n\n"],
            ["type": "text", "text": Self.estimateJSON],
        ])
        let estimate = try MealCarbEstimator.parseResponse(data)
        #expect(estimate.roundedCarbs == 10.8)
        #expect(estimate.absorptionReason == "2 t: melkeprodukt med sukker.")
        #expect(throws: (any Error).self) {
            try MealCarbEstimator.parseResponse(Self.response([["type": "text", "text": "Søker …"]], stop: "pause_turn"))
        }
    }

    @Test("the search request has the web search tool and no enforced schema; the other one has the schema")
    func searchRequest() throws {
        let conversation = [MealCarbEstimator.Message(role: "user", content: "Tine Yoghurt Junior klemmepose")]
        let search = MealCarbEstimator.requestBody(model: "claude-sonnet-5-5", conversation: conversation, webSearch: true)
        let tool = try #require((search["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "web_search_20260209")
        #expect((search["output_config"] as? [String: Any])?["format"] == nil)
        let plain = MealCarbEstimator.requestBody(model: "claude-sonnet-5-5", conversation: conversation)
        #expect(plain["tools"] == nil)
        #expect((plain["output_config"] as? [String: Any])?["format"] != nil)
    }

    // MARK: Favorites

    @Test("only the most eaten favorites are quick picks, counted from the dish name")
    func mostUsedFavorites() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let favorites = (1 ... 12).map { StoredFavoriteFood(id: "f\($0)", name: "Mat \($0)", carbs: 10, foodType: "🍽", absorptionTime: 7200) }
        var entries: [FavoriteFoodUsage.LoggedEntry] = []
        for day in 0 ..< 5 { entries.append(.init(foodType: "🥛 Mat 12", date: now.addingTimeInterval(-Double(day) * 86400))) }
        for day in 0 ..< 3 { entries.append(.init(foodType: "Mat 7", date: now.addingTimeInterval(-Double(day) * 86400 - 3600))) }
        // Logged twice within a minute: one serving. Too old: not counted.
        entries.append(.init(foodType: "Mat 3", date: now.addingTimeInterval(-100)))
        entries.append(.init(foodType: "Mat 3", date: now.addingTimeInterval(-80)))
        entries.append(.init(foodType: "Mat 3", date: now.addingTimeInterval(-100 * 86400)))
        let log = FavoriteFoodUsage.recording(entries, favorites: favorites, into: [:], now: now)
        #expect(log["f3"]?.count == 1)
        let top = FavoriteFoodUsage.mostUsed(favorites, log: log, now: now)
        #expect(top.count == 6)
        #expect(top.prefix(3).map(\.id) == ["f12", "f7", "f3"])
    }
}
