// LoopFollow
// EveningWatchText.swift

import Foundation

/// The evening watch's words, in their own table (EveningWatch.xcstrings).
enum EveningWatchText {
    static func units(_ units: Double) -> String {
        Localizer.formatToLocalizedString(units, maxFractionDigits: 2)
    }

    static func glucose(_ value: Double) -> String {
        "\(Localizer.formatQuantity(value)) \(UnitSettingsStore.shared.glucoseUnit.rawValue)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static var name: String {
        String(localized: "Evening Watch", table: "EveningWatch", comment: "Name of the evening watch in the alarm list and on its screens")
    }

    /// "🌙 Kveldsvakt: 0,5 E?"
    static func title(_ suggestion: EveningWatch.Suggestion?) -> String {
        guard let suggestion else { return "🌙 " + name }
        return String(format: String(localized: "🌙 Evening watch: %@ U?", table: "EveningWatch", comment: "Title of an evening watch suggestion (1: units)"), units(suggestion.units))
    }

    static func body(_ suggestion: EveningWatch.Suggestion?, settings: EveningWatch.Settings) -> String {
        guard let suggestion else { return "" }
        let minutes = String(Int(settings.persistent / 60))
        if let iob = suggestion.iob {
            return String(
                format: String(localized: "%1$@ and not falling for %2$@ min, no dose or meal for a while, %3$@ U on board.", table: "EveningWatch", comment: "Why the evening watch suggests a dose (1: glucose)(2: minutes)(3: insulin on board)"),
                glucose(suggestion.glucose), minutes, units(iob)
            )
        }
        return String(
            format: String(localized: "%1$@ and not falling for %2$@ min, no dose or meal for a while.", table: "EveningWatch", comment: "Why the evening watch suggests a dose, insulin on board unknown (1: glucose)(2: minutes)"),
            glucose(suggestion.glucose), minutes
        )
    }

    static var review: String {
        String(localized: "Review", table: "EveningWatch", comment: "Button: opens the bolus screen filled in with the evening watch's dose")
    }

    static var notNow: String {
        String(localized: "Not now", table: "EveningWatch", comment: "Button: declines the evening watch's suggestion and keeps it quiet for 30 minutes")
    }

    static var doneForTonight: String {
        String(localized: "Done for tonight", table: "EveningWatch", comment: "Button: declines the suggestion and keeps the evening watch quiet for the rest of the evening")
    }

    static var reviewHint: String {
        String(localized: "Nothing is sent until you confirm on the bolus screen.", table: "EveningWatch", comment: "Under the evening watch's buttons")
    }

    static var noRemoteHint: String {
        String(localized: "Give it in Loop, or set up remote control to send it from here.", table: "EveningWatch", comment: "Under the evening watch's buttons when remote bolus is not set up")
    }

    // MARK: - Log

    static func decision(_ decision: EveningWatch.Decision) -> String {
        let until = decision.until.map(time) ?? ""
        switch decision.kind {
        case .noFreshGlucose:
            return String(localized: "No recent glucose", table: "EveningWatch", comment: "Evening watch log")
        case .belowLimit:
            return String(localized: "Under the limit", table: "EveningWatch", comment: "Evening watch log")
        case .notPersistent:
            return String(localized: "Not high for long enough yet", table: "EveningWatch", comment: "Evening watch log")
        case .falling:
            return String(format: String(localized: "Falling (%@)", table: "EveningWatch", comment: "Evening watch log (1: glucose change)"), signedGlucose(decision.value ?? 0))
        case .recentLow:
            return String(format: String(localized: "Was under %@ in the last 90 min", table: "EveningWatch", comment: "Evening watch log (1: glucose)"), glucose(EveningWatch.Rule.lowFloor))
        case .recentCarbs:
            let at = decision.until.map { time($0.addingTimeInterval(-EveningWatch.Rule.carbGap)) } ?? ""
            return String(format: String(localized: "Meal at %1$@, waits until %2$@", table: "EveningWatch", comment: "Evening watch log (1: time of the meal)(2: time)"), at, until)
        case .recentBolus:
            let at = decision.until.map { time($0.addingTimeInterval(-EveningWatch.Rule.bolusGap)) } ?? ""
            return String(format: String(localized: "Dose at %1$@, waits until %2$@", table: "EveningWatch", comment: "Evening watch log (1: time of the dose)(2: time)"), at, until)
        case .recentSuggestion:
            let at = decision.until.map { time($0.addingTimeInterval(-EveningWatch.Rule.suggestionGap)) } ?? ""
            return String(format: String(localized: "Suggested at %1$@, waits until %2$@", table: "EveningWatch", comment: "Evening watch log (1: time of the last suggestion)(2: time)"), at, until)
        case .enoughTonight:
            return String(localized: "Three suggestions tonight already", table: "EveningWatch", comment: "Evening watch log")
        case .highIOB:
            return String(format: String(localized: "%@ U on board", table: "EveningWatch", comment: "Evening watch log (1: insulin on board)"), units(decision.value ?? 0))
        case .tooSmall:
            return String(localized: "Dose under 0.1 U", table: "EveningWatch", comment: "Evening watch log")
        case .suggested:
            return String(format: String(localized: "Suggested %@ U", table: "EveningWatch", comment: "Evening watch log (1: units)"), units(decision.value ?? 0))
        case .open:
            return String(localized: "Suggestion waiting", table: "EveningWatch", comment: "Evening watch log")
        case .lapsed:
            return String(localized: "Came down by itself, suggestion withdrawn", table: "EveningWatch", comment: "Evening watch log")
        }
    }

    static func state(_ suggestion: EveningWatch.Suggestion) -> String {
        switch suggestion.state {
        case .open:
            return String(localized: "Waiting", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case .given:
            return String(format: String(localized: "Given %@ U", table: "EveningWatch", comment: "State of an evening watch suggestion (1: units given)"), units(suggestion.givenUnits ?? suggestion.units))
        case .declined:
            return String(localized: "Declined", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case .expired:
            return String(localized: "Not answered", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case .lapsed:
            return String(localized: "Withdrawn", table: "EveningWatch", comment: "State of an evening watch suggestion")
        }
    }

    /// What followed a given suggestion and what it did to the dose; nil when not given.
    static func outcome(_ suggestion: EveningWatch.Suggestion) -> String? {
        guard suggestion.state == .given else { return nil }
        guard let outcome = suggestion.outcome else {
            return String(localized: "Judged 3 h after", table: "EveningWatch", comment: "Evening watch: a given suggestion not yet judged")
        }
        guard let lowest = outcome.lowest else {
            return String(localized: "Too few readings to learn from", table: "EveningWatch", comment: "Evening watch: a given suggestion that could not be judged")
        }
        return String(
            format: String(localized: "2 h: %1$@ · lowest %2$@ · dose %3$@ → %4$@ U", table: "EveningWatch", comment: "Evening watch: what followed a given suggestion (1: glucose after 2 h)(2: lowest within 3 h)(3: dose before)(4: dose after)"),
            outcome.after2h.map { Localizer.formatQuantity($0) } ?? "–",
            Localizer.formatQuantity(lowest),
            units(outcome.unitsBefore),
            units(outcome.unitsAfter)
        )
    }

    private static func signedGlucose(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + Localizer.formatQuantity(abs(value))
    }

    // MARK: - Settings

    static var explanation: String {
        String(localized: "In the evening, when glucose has stayed high for a while without falling and no dose or meal has been given lately, suggests a correction to send from here. It goes by glucose itself, not by Loop's forecast, and learns the dose from the suggestions that are given: smaller after a low, larger when glucose stays high. It never gives anything by itself.", table: "EveningWatch", comment: "Explanation at the top of the evening watch settings")
    }

    static func rules(settings: EveningWatch.Settings) -> String {
        String(
            format: String(localized: "Also waits 90 min after a meal, 60 min after a dose and 60 min between suggestions, at most three an evening, and never after a reading under %@ in the last 90 min.", table: "EveningWatch", comment: "The evening watch's fixed rules (1: glucose)"),
            glucose(EveningWatch.Rule.lowFloor)
        )
    }

    static var doseFooter: String {
        String(
            format: String(localized: "The dose before anything is learned. Under %1$@ and from %2$@ it is 30 %% smaller, and never over the maximum bolus.", table: "EveningWatch", comment: "Footer of the evening watch's start dose (1: glucose)(2: time of day)"),
            glucose(EveningWatch.Rule.smallerBelow),
            String(format: "%02d:%02d", EveningWatch.Rule.lateFrom / 60, EveningWatch.Rule.lateFrom % 60)
        )
    }
}
