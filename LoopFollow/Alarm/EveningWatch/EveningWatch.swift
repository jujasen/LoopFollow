// LoopFollow
// EveningWatch.swift

import Foundation

/// The evening watch («Kveldsvakt»). In the evening, once glucose has stayed high for half an
/// hour without falling and nothing has been given or eaten for a while, it suggests a
/// correction to send from here. It never doses by itself.
///
/// It looks at glucose itself and never at Loop's forecast. On Walter's evenings Loop expects
/// the insulin on board to bring glucose down much further than it does — over 30 evenings in
/// October 2026, when Loop forecast under 6 mmol/L within 3 h while he was over 10, he stayed
/// over 8 in 83 % of cases — so the AI meal watch in Loop, which leaned on that forecast, never
/// spoke.
///
/// The dose starts at the size of the evening corrections given by hand: 13 of 0.5 U that
/// month, none followed by glucose under 5 within 3 h and 11 still over 10 after 2 h. It is
/// smaller just over the limit and late in the evening, and learns from the suggestions that
/// are given: smaller after a low, larger when glucose stayed high.
///
/// Replayed over those 30 evenings the rules would have spoken on 21, one to three times,
/// the first usually around 21:45.
///
/// All glucose values are mg/dL.
enum EveningWatch {
    struct Settings: Equatable {
        /// Minutes after midnight; the window may run past midnight, and is the whole day when
        /// they are the same.
        var start = 19 * 60 + 30
        var end = 30
        /// Glucose at or above this.
        var glucose: Double = 198
        /// Every reading over this long must be at most 1 mmol/L under `glucose`.
        var persistent: TimeInterval = 30 * 60
        /// No suggestion with this much insulin on board or more.
        var maximumIOB: Double = 1.5
        /// The dose before anything is learned.
        var startUnits: Double = 0.5
    }

    /// The fixed rules.
    enum Rule {
        static let persistentMargin = 18.0
        static let falling15 = -4.0
        static let falling30 = -5.0
        /// No suggestion when a reading under this was seen within `lowLookback`.
        static let lowFloor = 108.0
        static let lowLookback: TimeInterval = 90 * 60
        /// A meal has this long to show what it does.
        static let carbGap: TimeInterval = 90 * 60
        static let minimumCarbs = 3.0
        /// A dose given by hand has this long.
        static let bolusGap: TimeInterval = 60 * 60
        static let suggestionGap: TimeInterval = 60 * 60
        static let perEvening = 3
        /// An unanswered suggestion lapses after this.
        static let lifetime: TimeInterval = 20 * 60
        /// Below this, and from `lateFrom`, the dose is scaled by `smaller`.
        static let smallerBelow = 216.0
        static let lateFrom = 23 * 60 + 30
        static let smaller = 0.7
        /// An open suggestion lapses when glucose falls this fast over 15 minutes.
        static let lapseFalling = -9.0
        static let learnedRange = 0.25 ... 0.8
        static let minimumUnits = 0.1
        /// A given suggestion is judged on the three hours after it.
        static let outcomeAfter: TimeInterval = 3 * 3600
    }

    struct Input: Codable {
        /// Oldest first.
        var glucose: [GlucoseValue]
        /// Boluses given by hand or remotely, not Loop's automatic ones.
        var manualBoluses: [BolusEntry]
        var carbs: [CarbSample]
        var iob: Double?
        var maximumBolus: Double?
    }

    struct Suggestion: Codable, Equatable, Identifiable {
        enum State: String, Codable {
            case open
            /// A bolus was given after it.
            case given
            /// «Ikke nå» or «Ferdig for i kveld».
            case declined
            case expired
            /// Glucose came down or fell fast before it was answered.
            case lapsed
        }

        struct Outcome: Codable, Equatable {
            /// Nil when too few readings were seen to judge it.
            var lowest: Double?
            var after2h: Double?
            var unitsBefore: Double
            var unitsAfter: Double
        }

        var id = UUID()
        var date: Date
        var glucose: Double
        var change30: Double?
        var iob: Double?
        var units: Double
        /// What the learned dose was scaled by.
        var scale: Double
        var state: State = .open
        var closedAt: Date?
        var givenUnits: Double?
        var outcome: Outcome?
    }

    /// What one look found, for the log.
    struct Decision: Codable, Equatable {
        enum Kind: String, Codable {
            case noFreshGlucose, belowLimit, notPersistent, falling, recentLow, recentCarbs, recentBolus
            case recentSuggestion, enoughTonight, highIOB, tooSmall, suggested, open, lapsed
        }

        /// The reading looked at.
        var date: Date
        var glucose: Double?
        var kind: Kind
        /// When a wait ends.
        var until: Date?
        /// Units for a suggestion, the change for `falling`, insulin on board for `highIOB`.
        var value: Double?
    }

    struct State: Codable, Equatable {
        /// The dose before scaling, once something has been learned.
        var learnedUnits: Double?
        var suggestions: [Suggestion] = []
        var decisions: [Decision] = []

        var open: Suggestion? {
            suggestions.last { $0.state == .open }
        }
    }

    // MARK: - One look

    /// Closes and learns from earlier suggestions, then decides. `fire` is true while a
    /// suggestion is open.
    static func tick(_ state: State, input: Input, settings: Settings, now: Date, calendar: Calendar = .current) -> (state: State, fire: Bool) {
        var state = state
        prune(&state, now: now)
        close(&state, input: input, now: now)
        learn(&state, input: input, settings: settings, now: now)

        guard isInWindow(now, settings: settings, calendar: calendar) else {
            for index in state.suggestions.indices where state.suggestions[index].state == .open {
                state.suggestions[index].state = .lapsed
                state.suggestions[index].closedAt = now
            }
            return (state, false)
        }

        guard let latest = input.glucose.last, now.timeIntervalSince(latest.date) <= 10 * 60 else {
            record(&state, Decision(date: input.glucose.last?.date ?? now, glucose: nil, kind: .noFreshGlucose))
            return (state, state.open != nil)
        }
        let glucose = Double(latest.sgv)

        if let index = state.suggestions.lastIndex(where: { $0.state == .open }) {
            let fallingFast = (change(input.glucose, minutes: 15) ?? 0) < Rule.lapseFalling
            if glucose < settings.glucose - Rule.persistentMargin || fallingFast {
                state.suggestions[index].state = .lapsed
                state.suggestions[index].closedAt = now
                record(&state, Decision(date: latest.date, glucose: glucose, kind: .lapsed))
                return (state, false)
            }
            record(&state, Decision(date: latest.date, glucose: glucose, kind: .open, value: state.suggestions[index].units))
            return (state, true)
        }

        let decision = decide(state, input: input, settings: settings, now: now, calendar: calendar)
        record(&state, decision)
        guard decision.kind == .suggested, let units = decision.value else { return (state, false) }
        state.suggestions.append(Suggestion(
            date: now,
            glucose: glucose,
            change30: change(input.glucose, minutes: 30),
            iob: input.iob,
            units: units,
            scale: scale(glucose: glucose, at: now, calendar: calendar)
        ))
        return (state, true)
    }

    /// Whether this reading is worth a suggestion, and if not, why not.
    static func decide(_ state: State, input: Input, settings: Settings, now: Date, calendar: Calendar = .current) -> Decision {
        guard let latest = input.glucose.last else { return Decision(date: now, kind: .noFreshGlucose) }
        let glucose = Double(latest.sgv)
        func decision(_ kind: Decision.Kind, until: Date? = nil, value: Double? = nil) -> Decision {
            Decision(date: latest.date, glucose: glucose, kind: kind, until: until, value: value)
        }

        guard glucose >= settings.glucose else { return decision(.belowLimit) }
        guard isPersistent(input.glucose, latest: latest, settings: settings) else { return decision(.notPersistent) }
        if let delta = change(input.glucose, minutes: 15), delta < Rule.falling15 { return decision(.falling, value: delta) }
        if let delta = change(input.glucose, minutes: 30), delta < Rule.falling30 { return decision(.falling, value: delta) }
        if input.glucose.contains(where: { latest.date.timeIntervalSince($0.date) <= Rule.lowLookback && Double($0.sgv) < Rule.lowFloor }) {
            return decision(.recentLow)
        }
        if let carb = input.carbs.last(where: { $0.grams >= Rule.minimumCarbs && $0.date <= now && now.timeIntervalSince($0.date) < Rule.carbGap }) {
            return decision(.recentCarbs, until: carb.date.addingTimeInterval(Rule.carbGap))
        }
        if let bolus = input.manualBoluses.last(where: { $0.units >= 0.05 && $0.date <= now && now.timeIntervalSince($0.date) < Rule.bolusGap }) {
            return decision(.recentBolus, until: bolus.date.addingTimeInterval(Rule.bolusGap))
        }
        if let last = state.suggestions.last, now.timeIntervalSince(last.date) < Rule.suggestionGap {
            return decision(.recentSuggestion, until: last.date.addingTimeInterval(Rule.suggestionGap))
        }
        let eveningStart = windowStart(before: now, settings: settings, calendar: calendar)
        if state.suggestions.filter({ $0.date >= eveningStart }).count >= Rule.perEvening {
            return decision(.enoughTonight)
        }
        if let iob = input.iob, iob >= settings.maximumIOB { return decision(.highIOB, value: iob) }

        let units = dose(learned: state.learnedUnits, settings: settings, glucose: glucose, at: now, maximumBolus: input.maximumBolus, calendar: calendar)
        guard units >= Rule.minimumUnits else { return decision(.tooSmall, value: units) }
        return decision(.suggested, value: units)
    }

    // MARK: - Dose

    static func scale(glucose: Double, at date: Date, calendar: Calendar = .current) -> Double {
        var scale = 1.0
        if glucose < Rule.smallerBelow { scale *= Rule.smaller }
        let minute = minutes(date, calendar: calendar)
        if minute >= Rule.lateFrom || minute < 6 * 60 { scale *= Rule.smaller }
        return scale
    }

    /// The learned dose scaled for this glucose and hour, within the maximum bolus, rounded down
    /// to the pod's 0.05 U.
    static func dose(learned: Double?, settings: Settings, glucose: Double, at date: Date, maximumBolus: Double?, calendar: Calendar = .current) -> Double {
        var units = (learned ?? settings.startUnits) * scale(glucose: glucose, at: date, calendar: calendar)
        if let maximumBolus, maximumBolus > 0 { units = min(units, maximumBolus) }
        return ((units * 20) + 1e-9).rounded(.down) / 20
    }

    /// How a given suggestion changes the learned dose: smaller after a low, larger when
    /// glucose was still high two hours on, otherwise unchanged.
    static func learnedUnits(before: Double, given: Double, scale: Double, lowest: Double, after2h: Double?) -> Double {
        let base = scale > 0 ? given / scale : given
        let units: Double
        if lowest < 72 {
            units = min(before, base) * 0.6
        } else if lowest < 90 {
            units = min(before, base) * 0.8
        } else if let after2h, after2h >= 216, lowest >= 126 {
            units = before * 1.1
        } else {
            return before
        }
        return min(max(units, Rule.learnedRange.lowerBound), Rule.learnedRange.upperBound)
    }

    // MARK: - Steps

    private static func prune(_ state: inout State, now: Date) {
        state.suggestions.removeAll { now.timeIntervalSince($0.date) > 14 * 24 * 3600 }
        state.decisions.removeAll { now.timeIntervalSince($0.date) > 72 * 3600 }
    }

    /// A bolus after an open suggestion makes it given; one past its time lapses.
    private static func close(_ state: inout State, input: Input, now: Date) {
        for index in state.suggestions.indices where state.suggestions[index].state == .open {
            let suggestion = state.suggestions[index]
            if let bolus = input.manualBoluses.first(where: { $0.date >= suggestion.date.addingTimeInterval(-60) && $0.units >= 0.05 }) {
                state.suggestions[index].state = .given
                state.suggestions[index].givenUnits = bolus.units
                state.suggestions[index].closedAt = bolus.date
            } else if now.timeIntervalSince(suggestion.date) >= Rule.lifetime {
                state.suggestions[index].state = .expired
                state.suggestions[index].closedAt = suggestion.date.addingTimeInterval(Rule.lifetime)
            }
        }
    }

    private static func learn(_ state: inout State, input: Input, settings: Settings, now: Date) {
        for index in state.suggestions.indices {
            let suggestion = state.suggestions[index]
            guard suggestion.state == .given, suggestion.outcome == nil, let givenAt = suggestion.closedAt,
                  now.timeIntervalSince(givenAt) >= Rule.outcomeAfter
            else { continue }
            let before = state.learnedUnits ?? settings.startUnits
            let readings = input.glucose.filter { $0.date >= givenAt && $0.date <= givenAt.addingTimeInterval(Rule.outcomeAfter) }
            // Two of the three hours, or it is not judged.
            guard readings.count >= 24, let lowest = readings.map({ Double($0.sgv) }).min() else {
                state.suggestions[index].outcome = .init(lowest: nil, after2h: nil, unitsBefore: before, unitsAfter: before)
                continue
            }
            let after2h = reading(near: givenAt.addingTimeInterval(2 * 3600), in: input.glucose).map { Double($0.sgv) }
            let after = learnedUnits(before: before, given: suggestion.givenUnits ?? suggestion.units, scale: suggestion.scale, lowest: lowest, after2h: after2h)
            state.suggestions[index].outcome = .init(lowest: lowest, after2h: after2h, unitsBefore: before, unitsAfter: after)
            if after != before { state.learnedUnits = after }
        }
    }

    /// One entry per reading: a repeat of the same finding for the same reading is left out.
    private static func record(_ state: inout State, _ decision: Decision) {
        if let last = state.decisions.last, last.date == decision.date, last.kind == decision.kind { return }
        state.decisions.append(decision)
    }

    // MARK: - Glucose

    static func reading(near date: Date, in glucose: [GlucoseValue]) -> GlucoseValue? {
        glucose
            .filter { abs($0.date.timeIntervalSince(date)) <= 5 * 60 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The change from the reading `minutes` before the latest; nil without one.
    static func change(_ glucose: [GlucoseValue], minutes: Int) -> Double? {
        guard let latest = glucose.last,
              let earlier = reading(near: latest.date.addingTimeInterval(-Double(minutes) * 60), in: glucose)
        else { return nil }
        return Double(latest.sgv - earlier.sgv)
    }

    /// Every reading over `settings.persistent`, with no gap over 11 minutes, near the limit.
    static func isPersistent(_ glucose: [GlucoseValue], latest: GlucoseValue, settings: Settings) -> Bool {
        let since = latest.date.addingTimeInterval(-settings.persistent)
        let run = glucose.filter { $0.date >= since.addingTimeInterval(-60) && $0.date <= latest.date }
        guard let first = run.first, first.date <= since.addingTimeInterval(4 * 60) else { return false }
        for (earlier, later) in zip(run, run.dropFirst()) where later.date.timeIntervalSince(earlier.date) > 11 * 60 {
            return false
        }
        return run.allSatisfy { Double($0.sgv) >= settings.glucose - Rule.persistentMargin }
    }

    // MARK: - Window

    static func minutes(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func isInWindow(_ date: Date, settings: Settings, calendar: Calendar = .current) -> Bool {
        let minute = minutes(date, calendar: calendar)
        if settings.start == settings.end { return true }
        if settings.start < settings.end {
            return minute >= settings.start && minute < settings.end
        }
        return minute >= settings.start || minute < settings.end
    }

    /// The start of the window `date` is in, or of the last one before it.
    static func windowStart(before date: Date, settings: Settings, calendar: Calendar = .current) -> Date {
        let startToday = calendar.date(bySettingHour: settings.start / 60, minute: settings.start % 60, second: 0, of: date) ?? date
        if startToday <= date { return startToday }
        return calendar.date(byAdding: .day, value: -1, to: startToday) ?? startToday
    }

    /// The end of the window that started at or before `date`.
    static func windowEnd(after date: Date, settings: Settings, calendar: Calendar = .current) -> Date {
        let start = windowStart(before: date, settings: settings, calendar: calendar)
        let endSameDay = calendar.date(bySettingHour: settings.end / 60, minute: settings.end % 60, second: 0, of: start) ?? start
        if endSameDay > start { return endSameDay }
        return calendar.date(byAdding: .day, value: 1, to: endSameDay) ?? endSameDay
    }
}
