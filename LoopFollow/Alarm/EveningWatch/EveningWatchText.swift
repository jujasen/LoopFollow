// LoopFollow
// EveningWatchText.swift

import Foundation

/// The evening watch's words, in their own table (EveningWatch.xcstrings).
enum EveningWatchText {
    static func units(_ units: Double) -> String {
        Localizer.formatToLocalizedString(units, maxFractionDigits: 2)
    }

    static func unitsWithUnit(_ value: Double) -> String {
        "\(units(value)) \(String(localized: "U"))"
    }

    static func mmol(_ value: Double) -> String {
        Localizer.formatToLocalizedString(value, maxFractionDigits: 1, minFractionDigits: 1)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Minutes after midnight as "20:30".
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static var name: String {
        String(localized: "Evening Watch", table: "EveningWatch", comment: "Name of the evening watch in the alarm list and on its screens")
    }

    /// "🌙 Kveldsvakt: 0,35 E?"
    static func title(units value: Double) -> String {
        String(format: String(localized: "🌙 Evening watch: %@ U?", table: "EveningWatch", comment: "Title of an evening watch suggestion (1: units)"), units(value))
    }

    /// The alarm's title: the open suggestion, or the name.
    static func title(_ open: EveningWatch.Open?) -> String {
        open.map { title(units: $0.units) } ?? "🌙 " + name
    }

    static var staysHint: String {
        String(localized: "Stays until you answer, or until glucose comes down.", table: "EveningWatch", comment: "Under an evening watch suggestion: how long it stays")
    }

    static var review: String {
        String(localized: "Review", table: "EveningWatch", comment: "Button: opens the bolus screen filled in with the evening watch's dose")
    }

    static var notNow: String {
        String(localized: "Not now", table: "EveningWatch", comment: "Button: quiets the evening watch's alarm for 30 minutes; the suggestion stays")
    }

    static var decline: String {
        String(localized: "Decline", table: "EveningWatch", comment: "Button: declines the evening watch's suggestion, here and in Loop")
    }

    static var reviewHint: String {
        String(localized: "Nothing is sent until you confirm on the bolus screen. «Not now» keeps the suggestion on the main screen.", table: "EveningWatch", comment: "Under the evening watch's buttons")
    }

    static var noRemoteHint: String {
        String(localized: "Give it in Loop, or set up remote control to send it from here.", table: "EveningWatch", comment: "Under the evening watch's buttons when remote bolus is not set up")
    }

    /// The notification for an automatic dose: Loop's own words.
    static func doseNotificationTitle(_ note: EveningWatch.DoseNote) -> String {
        note.given
            ? String(format: String(localized: "🌙 Evening watch gave %@ U", table: "EveningWatch", comment: "Notification when the evening watch gave a dose by itself (1: units)"), units(note.units))
            : String(format: String(localized: "🌙 Evening watch could not give %@ U", table: "EveningWatch", comment: "Notification when the pump did not take the evening watch's dose (1: units)"), units(note.units))
    }

    // MARK: - Settings

    static var explanation: String {
        String(localized: "The evening watch runs in Loop on Walter's phone. In the evening, when glucose keeps rising or stays high and nothing has been given or eaten for a while, it suggests a correction or, in automatic mode, gives it. This alarm sounds for its suggestions; the suggestion stays on the main screen until you answer. Its settings are changed in Loop under Settings → Evening Watch.", table: "EveningWatch", comment: "Explanation at the top of the evening watch settings")
    }

    static func mode(_ mode: EveningWatch.LoopSettings.Mode?) -> String {
        switch mode {
        case .off?:
            return String(localized: "Off", table: "EveningWatch", comment: "Evening watch mode in Loop")
        case .suggest?:
            return String(localized: "Suggests", table: "EveningWatch", comment: "Evening watch mode in Loop")
        case .automatic?:
            return String(localized: "Gives by itself", table: "EveningWatch", comment: "Evening watch mode in Loop")
        case nil:
            return "–"
        }
    }

    static var notUploaded: String {
        String(localized: "Loop has not sent its evening watch settings yet. They come with a Loop build that has the evening watch.", table: "EveningWatch", comment: "Evening watch settings when Loop's are unknown")
    }

    static var declineReachesLoop: String {
        String(localized: "«Decline» here also declines it in Loop, when the Nightscout token may write. Otherwise it is only hidden here.", table: "EveningWatch", comment: "Footer under the evening watch's settings from Loop")
    }

    // MARK: - Log

    static func decision(_ entry: EveningWatch.Log.Entry) -> String {
        let until = entry.until.map(time) ?? ""
        let value = entry.value ?? 0
        switch entry.kind {
        case "noFreshGlucose":
            return String(localized: "No recent glucose", table: "EveningWatch", comment: "Evening watch log")
        case "missingReadings":
            return String(localized: "Readings missing in the last half hour", table: "EveningWatch", comment: "Evening watch log")
        case "jump":
            return String(localized: "Sensor jump", table: "EveningWatch", comment: "Evening watch log: two readings too far apart")
        case "belowLimit":
            return String(localized: "Under the limit", table: "EveningWatch", comment: "Evening watch log")
        case "notRising":
            return String(localized: "Not rising enough", table: "EveningWatch", comment: "Evening watch log")
        case "falling":
            return String(localized: "Falling", table: "EveningWatch", comment: "Evening watch log")
        case "recentLow":
            return String(localized: "Was under 6 in the last 90 min", table: "EveningWatch", comment: "Evening watch log")
        case "recentCarbs":
            return String(format: String(localized: "Meal, waits until %@", table: "EveningWatch", comment: "Evening watch log (1: time)"), until)
        case "recentBolus":
            return String(format: String(localized: "Dose given, waits until %@", table: "EveningWatch", comment: "Evening watch log (1: time)"), until)
        case "recentAction":
            return String(format: String(localized: "Waits until %@ after the last one", table: "EveningWatch", comment: "Evening watch log (1: time)"), until)
        case "enoughTonight":
            return String(localized: "Enough for tonight", table: "EveningWatch", comment: "Evening watch log")
        case "noInsulinOnBoard":
            return String(localized: "Insulin on board unknown", table: "EveningWatch", comment: "Evening watch log")
        case "highIOB":
            return String(format: String(localized: "%@ U on board", table: "EveningWatch", comment: "Evening watch log (1: insulin on board)"), units(value))
        case "forecastLow":
            return String(format: String(localized: "Loop forecasts %@", table: "EveningWatch", comment: "Evening watch log (1: lowest forecast glucose)"), mmol(value))
        case "reducedInsulin":
            return String(localized: "Override with less insulin on", table: "EveningWatch", comment: "Evening watch log")
        case "cannotDose":
            return String(localized: "Closed loop off or pump busy", table: "EveningWatch", comment: "Evening watch log")
        case "tooSmall":
            return String(localized: "Dose under 0.1 U", table: "EveningWatch", comment: "Evening watch log")
        case "suggested":
            return String(format: String(localized: "Suggested %@ U", table: "EveningWatch", comment: "Evening watch log (1: units)"), units(value))
        case "dosed":
            return String(format: String(localized: "Gave %@ U", table: "EveningWatch", comment: "Evening watch log (1: units)"), units(value))
        case "open":
            return String(localized: "Suggestion waiting", table: "EveningWatch", comment: "Evening watch log")
        case "lapsed":
            return String(localized: "Suggestion no longer needed", table: "EveningWatch", comment: "Evening watch log")
        case "stopped":
            return String(format: String(localized: "Automatic turned off after %@", table: "EveningWatch", comment: "Evening watch log (1: lowest glucose)"), mmol(value))
        default:
            return entry.kind
        }
    }

    static func state(_ action: EveningWatch.Log.Action) -> String {
        switch action.state {
        case "open":
            return String(localized: "Waiting", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case "delivering":
            return String(localized: "Giving", table: "EveningWatch", comment: "State of an evening watch dose being delivered")
        case "given":
            return String(format: String(localized: "Given %@ U", table: "EveningWatch", comment: "State of an evening watch dose (1: units given)"), units(action.givenUnits ?? action.units))
        case "declined":
            return String(localized: "Declined", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case "lapsed":
            return String(localized: "No longer needed", table: "EveningWatch", comment: "State of an evening watch suggestion")
        case "failed":
            return String(localized: "Not delivered", table: "EveningWatch", comment: "State of an evening watch dose the pump did not take")
        default:
            return action.state
        }
    }

    /// "Automatisk · 10,8 og stiger" or "Forslag · 12,5, høy".
    static func describe(_ action: EveningWatch.Log.Action) -> String {
        let kind = action.isAutomatic
            ? String(localized: "Automatic", table: "EveningWatch", comment: "An evening watch dose given by itself")
            : String(localized: "Suggestion", table: "EveningWatch", comment: "An evening watch suggestion")
        let glucose = action.glucose.map(mmol) ?? "–"
        let why = action.trigger == "high"
            ? String(format: String(localized: "%@, high", table: "EveningWatch", comment: "Evening watch: glucose high (1: glucose)"), glucose)
            : String(format: String(localized: "%@ and rising", table: "EveningWatch", comment: "Evening watch: glucose rising (1: glucose)"), glucose)
        return "\(kind) · \(why)"
    }
}
