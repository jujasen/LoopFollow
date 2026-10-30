// LoopFollow
// EveningWatchTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct EveningWatchTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()

    private let settings = EveningWatch.Settings()

    /// 29 October 2026 at this time in Oslo; hours past 24 are the next morning.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    /// Readings every 5 minutes up to `end`, the last one `values.last`.
    private func glucose(_ values: [Int], endingAt end: Date) -> [GlucoseValue] {
        values.enumerated().map { index, sgv in
            GlucoseValue(sgv: sgv, date: end.addingTimeInterval(-Double(values.count - 1 - index) * 300))
        }
    }

    /// High and flat for the last hour.
    private func highInput(_ sgv: Int = 240, at end: Date, iob: Double? = 0.6) -> EveningWatch.Input {
        EveningWatch.Input(glucose: glucose(Array(repeating: sgv, count: 13), endingAt: end), manualBoluses: [], carbs: [], iob: iob, maximumBolus: 3)
    }

    private func decide(_ input: EveningWatch.Input, _ state: EveningWatch.State = .init(), at date: Date) -> EveningWatch.Decision {
        EveningWatch.decide(state, input: input, settings: settings, now: date, calendar: calendar)
    }

    // MARK: - Window

    @Test("#window — 19:30 to 00:30, across midnight")
    func window() {
        #expect(!EveningWatch.isInWindow(at(19, 29), settings: settings, calendar: calendar))
        #expect(EveningWatch.isInWindow(at(19, 30), settings: settings, calendar: calendar))
        #expect(EveningWatch.isInWindow(at(24, 15), settings: settings, calendar: calendar))
        #expect(!EveningWatch.isInWindow(at(24, 30), settings: settings, calendar: calendar))
        #expect(!EveningWatch.isInWindow(at(14), settings: settings, calendar: calendar))
        #expect(EveningWatch.windowStart(before: at(24, 10), settings: settings, calendar: calendar) == at(19, 30))
        #expect(EveningWatch.windowEnd(after: at(21), settings: settings, calendar: calendar) == at(24, 30))
        #expect(EveningWatch.windowEnd(after: at(24, 10), settings: settings, calendar: calendar) == at(24, 30))
    }

    // MARK: - Deciding

    @Test("#decide — high and flat for half an hour, nothing given: suggests the start dose")
    func suggests() {
        let decision = decide(highInput(at: at(21)), at: at(21))
        #expect(decision.kind == .suggested)
        #expect(decision.value == 0.5)
    }

    @Test("#decide — smaller under 12 mmol/L and from 23:30, never over the maximum bolus")
    func scaledDose() {
        #expect(decide(highInput(210, at: at(21)), at: at(21)).value == 0.35)
        #expect(decide(highInput(240, at: at(23, 45)), at: at(23, 45)).value == 0.35)
        #expect(decide(highInput(240, at: at(24, 10)), at: at(24, 10)).value == 0.35)
        #expect(decide(highInput(210, at: at(23, 45)), at: at(23, 45)).value == 0.2)
        var input = highInput(at: at(21))
        input.maximumBolus = 0.3
        #expect(decide(input, at: at(21)).value == 0.3)
    }

    @Test("#decide — under the limit, or not high for long enough")
    func notHighEnough() {
        #expect(decide(highInput(190, at: at(21)), at: at(21)).kind == .belowLimit)
        var input = highInput(at: at(21))
        input.glucose = glucose([150, 160, 170, 170, 175, 190, 200, 210, 220, 240], endingAt: at(21))
        #expect(decide(input, at: at(21)).kind == .notPersistent)
        // A gap in the readings breaks the run.
        input.glucose = highInput(at: at(21)).glucose.filter { abs($0.date.timeIntervalSince(at(20, 45))) > 360 }
        #expect(decide(input, at: at(21)).kind == .notPersistent)
    }

    @Test("#decide — falling")
    func falling() {
        var input = highInput(at: at(21))
        input.glucose = glucose([260, 260, 260, 260, 260, 260, 260, 255, 250, 248, 245, 240, 236], endingAt: at(21))
        let decision = decide(input, at: at(21))
        #expect(decision.kind == .falling)
        #expect(decision.value == -12)
    }

    @Test("#decide — waits after a low, a meal, a dose and a suggestion")
    func waits() {
        var input = highInput(at: at(21))
        input.glucose = glucose([100] + Array(repeating: 240, count: 17), endingAt: at(21))
        #expect(decide(input, at: at(21)).kind == .recentLow)

        input = highInput(at: at(21))
        input.carbs = [CarbSample(grams: 7, date: at(20))]
        #expect(decide(input, at: at(21)) == .init(date: at(21), glucose: 240, kind: .recentCarbs, until: at(21, 30)))
        input.carbs = [CarbSample(grams: 2, date: at(20))]
        #expect(decide(input, at: at(21)).kind == .suggested)

        input = highInput(at: at(21))
        input.manualBoluses = [BolusEntry(units: 0.5, date: at(20, 30))]
        #expect(decide(input, at: at(21)).until == at(21, 30))

        var state = EveningWatch.State()
        state.suggestions = [.init(date: at(20, 30), glucose: 230, units: 0.5, scale: 1, state: .declined)]
        #expect(decide(highInput(at: at(21)), state, at: at(21)).kind == .recentSuggestion)
        state.suggestions = (0 ..< 3).map { .init(date: at(19, 40 + $0 * 10), glucose: 230, units: 0.5, scale: 1, state: .given) }
        #expect(decide(highInput(at: at(21)), state, at: at(21)).kind == .enoughTonight)
    }

    @Test("#decide — too much insulin on board")
    func highIOB() {
        #expect(decide(highInput(at: at(21), iob: 1.6), at: at(21)).kind == .highIOB)
        #expect(decide(highInput(at: at(21), iob: nil), at: at(21)).kind == .suggested)
    }

    // MARK: - Ticks

    @Test("#tick — fires while the suggestion is open, then it is given, expires or lapses")
    func suggestionLife() {
        var (state, fire) = EveningWatch.tick(.init(), input: highInput(at: at(21)), settings: settings, now: at(21), calendar: calendar)
        #expect(fire)
        #expect(state.open?.units == 0.5)

        (state, fire) = EveningWatch.tick(state, input: highInput(at: at(21, 5)), settings: settings, now: at(21, 5), calendar: calendar)
        #expect(fire)
        #expect(state.suggestions.count == 1)

        var given = highInput(at: at(21, 10))
        given.manualBoluses = [BolusEntry(units: 0.45, date: at(21, 8))]
        let afterBolus = EveningWatch.tick(state, input: given, settings: settings, now: at(21, 10), calendar: calendar)
        #expect(!afterBolus.fire)
        #expect(afterBolus.state.suggestions.last?.state == .given)
        #expect(afterBolus.state.suggestions.last?.givenUnits == 0.45)
        #expect(afterBolus.state.decisions.last?.kind == .recentBolus)

        let expired = EveningWatch.tick(state, input: highInput(at: at(21, 20)), settings: settings, now: at(21, 20), calendar: calendar)
        #expect(!expired.fire)
        #expect(expired.state.suggestions.last?.state == .expired)

        var down = highInput(at: at(21, 10))
        down.glucose = glucose([240, 240, 240, 230, 215, 175], endingAt: at(21, 10))
        let lapsed = EveningWatch.tick(state, input: down, settings: settings, now: at(21, 10), calendar: calendar)
        #expect(!lapsed.fire)
        #expect(lapsed.state.suggestions.last?.state == .lapsed)
    }

    @Test("#tick — quiet and closes what is open outside the evening")
    func outsideWindow() {
        var state = EveningWatch.State()
        state.suggestions = [.init(date: at(24, 25), glucose: 230, units: 0.35, scale: 0.7)]
        let result = EveningWatch.tick(state, input: highInput(at: at(24, 31)), settings: settings, now: at(24, 31), calendar: calendar)
        #expect(!result.fire)
        #expect(result.state.suggestions.last?.state == .lapsed)
        #expect(result.state.decisions.isEmpty)
    }

    @Test("#tick — one log entry per reading")
    func oneEntryPerReading() {
        var state = EveningWatch.State()
        let input = highInput(190, at: at(21))
        for second in [0, 60, 120] {
            state = EveningWatch.tick(state, input: input, settings: settings, now: at(21).addingTimeInterval(Double(second)), calendar: calendar).state
        }
        #expect(state.decisions.count == 1)
    }

    /// 29 October 2026: 0.5 U by hand at 20:19 and 21:02, glucose still climbing to 15.6.
    @Test("#tick — that evening it would have suggested 0.5 U at 22:04")
    func october29() {
        let readings: [(Int, Int, Int)] = [
            (20, 4, 222), (20, 9, 225), (20, 14, 222), (20, 19, 217), (20, 24, 219), (20, 29, 223), (20, 34, 223),
            (20, 39, 224), (20, 44, 224), (20, 49, 224), (20, 54, 227), (20, 59, 233), (21, 4, 238), (21, 9, 237),
            (21, 14, 237), (21, 29, 235), (21, 34, 229), (21, 39, 231), (21, 44, 236), (21, 49, 243), (21, 54, 249),
            (21, 59, 254), (22, 4, 259), (22, 9, 264), (22, 14, 274),
        ]
        let all = readings.map { GlucoseValue(sgv: $0.2, date: at($0.0, $0.1)) }
        let boluses = [BolusEntry(units: 0.5, date: at(20, 19)), BolusEntry(units: 0.5, date: at(21, 2))]
        let carbs = [CarbSample(grams: 20, date: at(18, 3)), CarbSample(grams: 7, date: at(18, 47))]
        var state = EveningWatch.State()
        var first: EveningWatch.Suggestion?
        for reading in all {
            let input = EveningWatch.Input(glucose: all.filter { $0.date <= reading.date }, manualBoluses: boluses.filter { $0.date <= reading.date }, carbs: carbs, iob: 0.85, maximumBolus: 3)
            state = EveningWatch.tick(state, input: input, settings: settings, now: reading.date.addingTimeInterval(30), calendar: calendar).state
            if first == nil { first = state.open }
        }
        #expect(first?.date == at(22, 4).addingTimeInterval(30))
        #expect(first?.units == 0.5)
        #expect(state.decisions.contains { $0.kind == .recentBolus && $0.until == at(22, 2) })
    }

    // MARK: - Learning

    @Test("#learnedUnits — smaller after a low, larger when still high, else unchanged")
    func learning() {
        #expect(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 65, after2h: 100) == 0.3)
        #expect(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 85, after2h: 120) == 0.4)
        #expect(abs(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 150, after2h: 230) - 0.55) < 1e-9)
        #expect(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 120, after2h: 180) == 0.5)
        // A larger dose given by hand that ended low never makes the next suggestion larger.
        #expect(EveningWatch.learnedUnits(before: 0.5, given: 1.0, scale: 1, lowest: 85, after2h: 120) == 0.4)
        // A scaled-down suggestion is judged as the dose before scaling.
        #expect(abs(EveningWatch.learnedUnits(before: 0.5, given: 0.35, scale: 0.7, lowest: 85, after2h: 120) - 0.4) < 1e-9)
        #expect(EveningWatch.learnedUnits(before: 0.8, given: 0.8, scale: 1, lowest: 150, after2h: 260) == 0.8)
        #expect(EveningWatch.learnedUnits(before: 0.3, given: 0.3, scale: 1, lowest: 60, after2h: 90) == 0.25)
    }

    @Test("#tick — learns three hours after a given suggestion")
    func learnsFromOutcome() {
        var state = EveningWatch.State()
        state.suggestions = [.init(date: at(21), glucose: 240, units: 0.5, scale: 1, state: .given, closedAt: at(21, 5), givenUnits: 0.5)]
        // Still 13 two hours on, never under 7.
        let after = glucose(Array(repeating: 234, count: 45), endingAt: at(24, 45))
        let input = EveningWatch.Input(glucose: after, manualBoluses: [BolusEntry(units: 0.5, date: at(21, 5))], carbs: [], iob: 0.5, maximumBolus: 3)
        let early = EveningWatch.tick(state, input: input, settings: settings, now: at(24), calendar: calendar).state
        #expect(early.suggestions[0].outcome == nil)
        let learned = EveningWatch.tick(state, input: input, settings: settings, now: at(24, 6), calendar: calendar).state
        #expect(learned.suggestions[0].outcome?.lowest == 234)
        #expect(abs((learned.learnedUnits ?? 0) - 0.55) < 1e-9)

        // Too few readings: noted, nothing learned.
        let sparse = EveningWatch.Input(glucose: Array(after.suffix(6)), manualBoluses: [], carbs: [], iob: 0.5, maximumBolus: 3)
        let unjudged = EveningWatch.tick(state, input: sparse, settings: settings, now: at(24, 6), calendar: calendar).state
        #expect(unjudged.suggestions[0].outcome?.lowest == nil)
        #expect(unjudged.learnedUnits == nil)
    }

    // MARK: - Condition

    @Test("#condition — reads the alarm's settings and keeps the state")
    func condition() {
        var alarm = Alarm(type: .eveningWatch)
        alarm.eveningStartUnits = 0.4
        let settings = EveningWatch.Settings(alarm: alarm)
        #expect(settings.start == 19 * 60 + 30)
        #expect(settings.end == 30)
        #expect(settings.glucose == 198)
        #expect(settings.maximumIOB == 1.5)
        #expect(settings.startUnits == 0.4)

        final class Box { var state = EveningWatch.State() }
        let box = Box()
        let condition = EveningWatchCondition(load: { box.state }, save: { box.state = $0 })
        let now = Date()
        var data = AlarmData(
            bgReadings: [], predictionData: [], expireDate: nil, lastLoopTime: nil, latestOverrideStart: nil,
            latestOverrideEnd: nil, latestTempTargetStart: nil, latestTempTargetEnd: nil, recBolus: nil, COB: nil,
            sageInsertTime: nil, pumpInsertTime: nil, latestPumpVolume: nil, IOB: nil, recentBoluses: [],
            latestBattery: nil, latestBatteryIsCharging: nil, latestPumpBattery: nil, batteryHistory: [],
            recentCarbs: [], dbSizePercentage: nil
        )
        #expect(!condition.evaluate(alarm: alarm, data: data, now: now))
        // Around the clock, so the test does not depend on when it runs.
        alarm.eveningStartMinutes = 0
        alarm.eveningEndMinutes = 0
        data.eveningWatch = highInput(at: now)
        #expect(condition.evaluate(alarm: alarm, data: data, now: now))
        #expect(box.state.open != nil)
    }
}
