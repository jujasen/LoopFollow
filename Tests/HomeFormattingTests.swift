// LoopFollow
// HomeFormattingTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The logic behind the redesigned Home: the loop ring's colour, the plain-language
/// statistics, the four numbers and the chart span control.
/// Strings are checked in English (the tests run with `-testLanguage en`).
struct HomeFormattingTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)
    private static let en = Locale(identifier: "en_US")

    // MARK: Loop ring

    @Test("#freshness — Loop's limits: green to 6 min, yellow to 16 min, red after")
    func freshness() {
        func at(_ seconds: TimeInterval) -> LoopFreshness {
            LoopFreshness(lastLoop: Self.now.addingTimeInterval(-seconds), now: Self.now)
        }
        #expect(at(0) == .fresh)
        #expect(at(6 * 60) == .fresh)
        #expect(at(6 * 60 + 1) == .aging)
        #expect(at(16 * 60) == .aging)
        #expect(at(16 * 60 + 1) == .stale)
        #expect(at(3 * 3600) == .stale)
        // A loop time a little in the future (clock skew) counts as fresh.
        #expect(at(-30) == .fresh)
        #expect(LoopFreshness(lastLoop: nil, now: Self.now) == .unknown)
        #expect(LoopFreshness(lastLoopTime: 0, now: Self.now) == .unknown)
        #expect(LoopFreshness(lastLoopTime: nil, now: Self.now) == .unknown)
        #expect(LoopFreshness(lastLoopTime: Self.now.timeIntervalSince1970 - 120, now: Self.now) == .fresh)
    }

    @Test("#ageText — minutes under the ring, then hours, then days")
    func ageText() {
        func text(_ seconds: TimeInterval) -> String {
            LoopFreshness.ageText(lastLoop: Self.now.addingTimeInterval(-seconds), now: Self.now)
        }
        #expect(text(30) == "0 min")
        #expect(text(2 * 60 + 50) == "2 min")
        #expect(text(59 * 60) == "59 min")
        #expect(text(75 * 60) == "1 h")
        #expect(text(50 * 3600) == "2 d")
        #expect(LoopFreshness.ageText(lastLoop: nil, now: Self.now) == "–")
    }

    // MARK: Statistics

    @Test("#durations — hours and minutes without commas")
    func durations() {
        #expect(HomeDurationFormat.hoursMinutes(30 * 60) == "30 min")
        #expect(HomeDurationFormat.hoursMinutes(4 * 3600) == "4 h")
        #expect(HomeDurationFormat.hoursMinutes(18 * 3600 + 43 * 60) == "18 h 43 min")
        #expect(HomeDurationFormat.hoursMinutes(-5) == "0 min")
    }

    @Test("#compact — a pod's age or a sensor's time left in the HUD, rounded down")
    func compactDurations() {
        #expect(HomeDurationFormat.compact(5 * 86400 + 23 * 3600 + 59 * 60) == "5 d 23 h")
        #expect(HomeDurationFormat.compact(2 * 86400 + 30 * 60) == "2 d")
        #expect(HomeDurationFormat.compact(7 * 3600 + 40 * 60) == "7 h")
        #expect(HomeDurationFormat.compact(3600) == "1 h")
        #expect(HomeDurationFormat.compact(80 * 60) == "1 h 20 min")
        #expect(HomeDurationFormat.compact(45 * 60 + 59) == "45 min")
        #expect(HomeDurationFormat.compact(-60) == "0 min")
    }

    @Test("#summary — very low and low make «low», high and very high make «high», with their time")
    func summaryBands() {
        let summary = TimeInRangeSummary(veryLow: 0.5, low: 1.5, inRange: 78, high: 15, veryHigh: 5,
                                         periodSeconds: 24 * 3600, sinceMidnight: false, hasData: true)
        #expect(summary.low.percent == 2)
        #expect(summary.inRange.percent == 78)
        #expect(summary.high.percent == 20)
        #expect(summary.low.duration == 0.02 * 24 * 3600)
        #expect(TimeInRangeSummary.durationText(summary.low, hasData: true) == "29 min")
        #expect(TimeInRangeSummary.durationText(summary.inRange, hasData: true) == "18 h 43 min")
        #expect(TimeInRangeSummary.durationText(summary.high, hasData: true) == "4 h 48 min")
        #expect(TimeInRangeSummary.durationText(summary.high, hasData: false) == "")
    }

    @Test("#headline — «Today» or «Last 24 h», and a dash without data")
    func headline() {
        let today = TimeInRangeSummary(veryLow: 0, low: 2, inRange: 78.4, high: 19.6, veryHigh: 0,
                                       periodSeconds: 12 * 3600, sinceMidnight: true, hasData: true)
        #expect(today.headline(locale: Self.en) == "Today: 78% in range")
        // Since midnight, the times are shares of the hours so far.
        #expect(today.inRange.duration == 12 * 3600 * 0.784)

        let day = TimeInRangeSummary(veryLow: 0, low: 0, inRange: 100, high: 0, veryHigh: 0,
                                     periodSeconds: 24 * 3600, sinceMidnight: false, hasData: true)
        #expect(day.headline(locale: Self.en) == "Last 24 h: 100% in range")

        let empty = TimeInRangeSummary(veryLow: 0, low: 0, inRange: 0, high: 0, veryHigh: 0,
                                       periodSeconds: 60, sinceMidnight: true, hasData: false)
        #expect(empty.headline(locale: Self.en) == "Today: – in range")
    }

    @Test("#percentText — a small low never reads as none")
    func percentText() {
        #expect(TimeInRangeSummary.percentText(0, locale: Self.en) == "0%")
        #expect(TimeInRangeSummary.percentText(0.3, locale: Self.en) == "<1%")
        #expect(TimeInRangeSummary.percentText(0.6, locale: Self.en) == "1%")
        #expect(TimeInRangeSummary.percentText(78.4, locale: Self.en) == "78%")
        // Norwegian puts a (non-breaking) space before the sign.
        let nb = TimeInRangeSummary.percentText(78, locale: Locale(identifier: "nb_NO"))
        #expect(nb.hasPrefix("78") && nb.hasSuffix("%") && nb.count == 4)
    }

    // MARK: The four numbers

    @Test("#basal — the rate running now, also when a temp basal differs from the schedule")
    func basal() {
        #expect(HomeNumbers.currentBasal(fromInfoValue: "0,6 → 0,45") == "0,45")
        #expect(HomeNumbers.currentBasal(fromInfoValue: "0,6") == "0,6")
        #expect(HomeNumbers.currentBasal(fromInfoValue: "0.6 → 0") == "0")
        #expect(HomeNumbers.currentBasal(fromInfoValue: " ") == nil)
        #expect(HomeNumbers.withUnit("1,8", "U") == "1,8 U")
        #expect(HomeNumbers.withUnit("", "U") == nil)
        #expect(HomeNumbers.withUnit("—", "g") == nil)
    }

    @Test("#forecast — Loop's curve in 30 minutes, interpolated between its five-minute points")
    func forecast() {
        let start = Self.now.addingTimeInterval(-2 * 60)
        let curve = LoopPredictionCurve(start: start, valuesMgdl: [130, 135, 140, 145, 150, 155, 160, 165, 170])
        #expect(curve.value(at: start) == 130)
        #expect(curve.value(at: start.addingTimeInterval(30 * 60)) == 160)
        // 30 minutes from now is 32 minutes into the curve: 160 + 2/5 of the way to 165.
        let inThirty = curve.value(at: Self.now.addingTimeInterval(30 * 60))
        #expect(inThirty.map { abs($0 - 162) < 0.0001 } == true)
        #expect(curve.value(at: start.addingTimeInterval(-60)) == nil)
        #expect(curve.value(at: start.addingTimeInterval(41 * 60)) == nil)
        #expect(LoopPredictionCurve(start: start, valuesMgdl: []).value(at: start) == nil)
    }

    // MARK: Chart span

    @Test("#span — picks the segment the chart shows, none after a pinch in between")
    func spanMatching() {
        #expect(ChartSpan.matching(visibleSeconds: 6 * 3600) == .six)
        #expect(ChartSpan.matching(visibleSeconds: 3 * 3600 + 120) == .three)
        #expect(ChartSpan.matching(visibleSeconds: 24 * 3600) == .twentyFour)
        #expect(ChartSpan.matching(visibleSeconds: 4.5 * 3600) == nil)
        #expect(ChartSpan.matching(visibleSeconds: 3600) == nil)
        #expect(ChartSpan.allCases.map(\.hours) == [3, 6, 12, 24])
        #expect(ChartSpan.six.label == "6 h")
    }

    @Test("#leadingEdge — «now» at 70 %, kept inside the loaded data")
    func leadingEdge() {
        let domainStart = Self.now.addingTimeInterval(-24 * 3600)
        let domainEnd = Self.now.addingTimeInterval(3 * 3600)
        let six = ChartSpan.leadingEdge(seconds: 6 * 3600, now: Self.now, nowFraction: 0.7, domainStart: domainStart, domainEnd: domainEnd)
        #expect(six == Self.now.addingTimeInterval(-6 * 3600 * 0.7))
        // 24 h with «now» at 70 % would run past the end of the forecast: it ends there instead.
        let day = ChartSpan.leadingEdge(seconds: 24 * 3600, now: Self.now, nowFraction: 0.7, domainStart: domainStart, domainEnd: domainEnd)
        #expect(day == domainEnd.addingTimeInterval(-24 * 3600))
        // With only 12 hours loaded, 24 h starts with the data.
        let halfDay = Self.now.addingTimeInterval(-12 * 3600)
        let short = ChartSpan.leadingEdge(seconds: 24 * 3600, now: Self.now, nowFraction: 0.7, domainStart: halfDay, domainEnd: domainEnd)
        #expect(short == halfDay)
        // Before the first load the domain is a placeholder and is not used.
        let placeholder = Date(timeIntervalSince1970: 0)
        let early = ChartSpan.leadingEdge(seconds: 3 * 3600, now: Self.now, nowFraction: 0.7, domainStart: placeholder, domainEnd: placeholder)
        #expect(early == Self.now.addingTimeInterval(-3 * 3600 * 0.7))
    }

    @Test("#infoTablePlacement — stored in the settings that already existed")
    func infoTablePlacement() {
        let hidden = Storage.shared.hideInfoTable.value
        let onHome = Storage.shared.infoTableOnHome.value
        defer {
            Storage.shared.hideInfoTable.value = hidden
            Storage.shared.infoTableOnHome.value = onHome
        }
        InfoTablePlacement.hidden.apply()
        #expect(Storage.shared.hideInfoTable.value && !Storage.shared.infoTableOnHome.value)
        #expect(InfoTablePlacement.current == .hidden)
        InfoTablePlacement.card.apply()
        #expect(!Storage.shared.hideInfoTable.value && Storage.shared.infoTableOnHome.value)
        #expect(InfoTablePlacement.current == .card)
        InfoTablePlacement.behindTap.apply()
        #expect(InfoTablePlacement.current == .behindTap)
        // Someone who had hidden the table before keeps it hidden.
        Storage.shared.infoTableOnHome.value = true
        Storage.shared.hideInfoTable.value = true
        #expect(InfoTablePlacement.current == .hidden)
    }
}
