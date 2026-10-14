// LoopFollow
// LoopInsightTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct LoopInsightTests {
    /// A document as Loop uploads it (GlucoseInsightDocument, ISO 8601 dates), trimmed.
    private static let uploaded: [String: Any] = [
        "_id": "6c6f6f70696e736967687431",
        "type": "loopInsight",
        "version": 1,
        "uploadedAt": "2026-10-14T08:05:00Z",
        "aiEnabled": true,
        "aiUsageToday": ["calls": 3, "dollars": 0.12],
        "created_at": "2026-10-14T08:05:01.000Z",
        "insight": [
            "dataUpdatedAt": "2026-10-14T08:00:00Z",
            "today": [
                "period": ["meanMmol": 7.4, "timeInRangePercent": 78, "belowRangePercent": 3, "aboveRangePercent": 19, "lowEpisodes": 1, "readings": 96],
                "lowEpisodeStarts": ["2026-10-14T06:10:00Z"],
                "hoursAboveTen": 1.5,
                "meals": [[
                    "date": "2026-10-14T05:30:00Z", "daypart": "morgen 06-09", "carbsGrams": 25, "foods": ["🥣 Havregrøt"],
                    "bolusUnits": 1.25, "automaticUnitsWithin3h": 0.3, "startMmol": 6.2, "peakMmol": 10.4,
                    "flags": ["treated_low", "something_new"],
                ]],
                "loopForecastError1hMmol": 1.6, "usualForecastError1hMmol": 0.3, "forecastDeviationMmol": 1.3,
                "computedAt": "2026-10-14T08:00:00Z",
            ],
            "longTerm": [
                "days": 30, "dayparts": [[
                    "name": "kveld 19-24", "loopForecastError2hMmol": 2.5, "forecastChecks": 80, "cleanMeals": 16,
                    "lowAfterMealPercent": 0, "highAt3hPercent": 56,
                ]],
                "averageDailyCarbsGrams": 140, "averageDailyBolusUnits": 6.2, "meals": [Any](),
                "advice": [["date": "2026-10-13T16:00:00Z", "loopUnits": 1.1, "suggestedUnits": 1.3, "accepted": true, "after3hMmol": 7.2]],
                "computedAt": "2026-10-14T08:00:00Z",
            ],
            "todayText": ["summary": "Litt mer insulinbehov enn vanlig.", "points": [], "dose_hints": ["Ikke mer enn Loop."], "created_at": "2026-10-14T07:30:00Z"],
        ],
    ]

    private let favorite: [String: Any] = ["_id": "652f00000000000000000001", "type": "food", "name": "Brødskive", "carbs": 15]

    @Test("Loop's document is found among the favorite foods and read")
    func readsTheDocument() throws {
        let document = try #require(LoopInsightDocument.find(in: [favorite, Self.uploaded]))
        #expect(document.aiEnabled)
        #expect(document.aiUsageToday.calls == 3)
        #expect(document.insight.today?.period?.timeInRangePercent == 78)
        #expect(document.insight.today?.forecastDeviationMmol == 1.3)
        #expect(document.insight.longTerm?.dayparts.first?.highAt3hPercent == 56)
        #expect(document.insight.longTerm?.advice.first?.accepted == true)
        #expect(document.insight.todayText?.doseHints == ["Ikke mer enn Loop."])
        #expect(document.uploadedAt == Date(timeIntervalSince1970: 1_791_965_100))
    }

    @Test("a meal flag this app doesn't know is dropped, not the meal")
    func unknownFlags() throws {
        let document = try #require(LoopInsightDocument.find(in: [Self.uploaded]))
        let meal = try #require(document.insight.today?.meals.first)
        #expect(meal.flags == [.treatedLow])
        #expect(meal.after3hMmol == nil)
    }

    @Test("no document, or only foods, gives nothing")
    func nothingToRead() {
        #expect(LoopInsightDocument.find(in: []) == nil)
        #expect(LoopInsightDocument.find(in: [favorite]) == nil)
        #expect(LoopInsightDocument.find(in: [["_id": LoopInsightDocument.id, "type": "loopInsight"]]) == nil, "an unreadable document is skipped")
    }

    @Test("the newest of two documents wins")
    func newestWins() throws {
        var older = Self.uploaded
        older["_id"] = "652f00000000000000000002"
        older["uploadedAt"] = "2026-10-13T08:05:00Z"
        let document = try #require(LoopInsightDocument.find(in: [older, Self.uploaded]))
        #expect(document.uploadedAt == Date(timeIntervalSince1970: 1_791_965_100))
    }

    @Test("the insight takes a free place, or else the Nightscout tab's, and only once")
    func placement() {
        let storage = Storage.shared
        let saved = TabItem.allCases.map { ($0, storage.position(for: $0)) }
        let savedPlaced = storage.insightTabPlaced.value
        defer {
            saved.forEach { storage.setPosition($0.1, for: $0.0) }
            storage.insightTabPlaced.value = savedPlaced
        }

        // All four places taken, as by default.
        storage.setPosition(.position1, for: .home)
        storage.setPosition(.position2, for: .alarms)
        storage.setPosition(.position3, for: .snoozer)
        storage.setPosition(.position4, for: .nightscout)
        for item in [TabItem.remote, .stats, .treatments, .insight] {
            storage.setPosition(.menu, for: item)
        }
        storage.insightTabPlaced.value = false
        storage.placeInsightTabOnce()
        #expect(storage.position(for: .insight) == .position4)
        #expect(storage.position(for: .nightscout) == .menu)

        // Moved back by hand: it stays where it was put.
        storage.setPosition(.position4, for: .nightscout)
        storage.setPosition(.menu, for: .insight)
        storage.placeInsightTabOnce()
        #expect(storage.position(for: .insight) == .menu)

        // A free place is used before the Nightscout tab's.
        storage.setPosition(.menu, for: .snoozer)
        storage.insightTabPlaced.value = false
        storage.placeInsightTabOnce()
        #expect(storage.position(for: .insight) == .position3)
        #expect(storage.position(for: .nightscout) == .position4)
    }

    @Test("the insight is a tab item with its own place")
    func tabItem() {
        #expect(TabItem.allCases.contains(.insight))
        #expect(TabItem.featureOrder.contains(.insight))
        #expect(TabItem.insight.icon == "sparkles")
    }
}
