// LoopFollow
// RemoteDoseViews.swift

// The pieces the meal and bolus screens share: what LoopFollow knows about the glucose and the
// insulin right now, Loop's prediction as a small chart, the big amount fields and the line that
// says what Loop will do with the command.

import Charts
import HealthKit
import SwiftUI

/// What LoopFollow last downloaded: glucose, insulin on board, the last bolus and Loop's prediction.
enum RemoteDoseContext {
    static func glucoseText() -> String? {
        guard let bg = Observable.shared.bg.value, bg > 0 else { return nil }
        let unit = UnitSettingsStore.shared.glucoseUnit
        var text = Localizer.formatQuantity(Double(bg)) + " " + unit.rawValue
        if let trend = trendText(direction: MainViewController.shared?.bgData.last?.direction) {
            text += ", " + trend
        }
        if Observable.shared.bgStale.value {
            text += " " + String(localized: "(old)", table: "MealBolus", comment: "After a glucose reading that is no longer current")
        }
        return text
    }

    static func trendText(direction: String?) -> String? {
        switch direction {
        case "DoubleUp": return String(localized: "rising fast", table: "MealBolus")
        case "SingleUp", "FortyFiveUp": return String(localized: "rising", table: "MealBolus")
        case "Flat": return String(localized: "steady", table: "MealBolus")
        case "FortyFiveDown", "SingleDown": return String(localized: "falling", table: "MealBolus")
        case "DoubleDown": return String(localized: "falling fast", table: "MealBolus")
        default: return nil
        }
    }

    static var insulinOnBoard: Double? {
        MainViewController.shared?.latestIOB?.value ?? Storage.shared.lastIOB.value
    }

    /// The latest bolus in Nightscout.
    static var lastBolus: (units: Double, date: Date)? {
        guard let last = MainViewController.shared?.bolusData.max(by: { $0.date < $1.date }) else { return nil }
        return (last.value, Date(timeIntervalSince1970: last.date))
    }

    static func units(_ value: Double) -> String {
        String(format: String(localized: "%@ U", table: "MealBolus", comment: "1: insulin units"), Localizer.formatToLocalizedString(value, maxFractionDigits: 2, minFractionDigits: 2))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    struct GlucosePoint: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// The last hour and a half of glucose and Loop's latest prediction, in the display unit.
    static func chartData(now: Date = Date()) -> (history: [GlucosePoint], prediction: [GlucosePoint]) {
        guard let main = MainViewController.shared else { return ([], []) }
        let toDisplay: (Int) -> Double = { mgdl in
            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)).doubleValue(for: Localizer.getPreferredUnit())
        }
        let from = now.addingTimeInterval(-90 * 60).timeIntervalSince1970
        let history = main.bgData.filter { $0.date >= from && $0.sgv > 0 }.map { GlucosePoint(date: Date(timeIntervalSince1970: $0.date), value: toDisplay($0.sgv)) }
        let prediction = main.predictionData.filter { $0.date >= now.timeIntervalSince1970 - 10 * 60 }.map { GlucosePoint(date: Date(timeIntervalSince1970: $0.date), value: toDisplay($0.sgv)) }
        return (history, prediction)
    }

    static func displayGlucose(_ mgdl: Double) -> Double {
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl).doubleValue(for: Localizer.getPreferredUnit())
    }
}

/// Glucose as dots and Loop's prediction as a dashed violet line, over the target range.
struct PredictionMiniChart: View {
    let title: String
    let history: [RemoteDoseContext.GlucosePoint]
    let prediction: [RemoteDoseContext.GlucosePoint]

    /// Whole hours, leaving out one at the right edge where the glucose labels would cover it.
    private var hourMarks: [Date] {
        let dates = (history + prediction).map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let calendar = Calendar.current
        guard var hour = calendar.nextDate(after: first, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) else { return [] }
        var marks: [Date] = []
        while hour < last.addingTimeInterval(-20 * 60) {
            marks.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return marks
    }

    private var peak: RemoteDoseContext.GlucosePoint? {
        prediction.max { $0.value < $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let peak {
                    Text(String(format: String(localized: "Peak %@ at %@", table: "MealBolus", comment: "1: glucose, 2: time"), Localizer.formatLocalDouble(peak.value), RemoteDoseContext.time(peak.date)))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.purple)
                }
            }
            Chart {
                RectangleMark(
                    yStart: .value("Low", RemoteDoseContext.displayGlucose(Storage.shared.lowLine.value)),
                    yEnd: .value("High", RemoteDoseContext.displayGlucose(Storage.shared.highLine.value))
                )
                .foregroundStyle(Color.green.opacity(0.1))
                ForEach(history) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Glucose", point.value))
                        .symbolSize(14)
                        .foregroundStyle(Color.green)
                }
                ForEach(prediction) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Prediction", point.value))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
                        .foregroundStyle(Color.purple)
                }
                RuleMark(x: .value("Now", Date()))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            .chartXAxis {
                AxisMarks(values: hourMarks) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
            }
            .frame(height: 130)
            .accessibilityLabel(title)
        }
        .padding(.vertical, 4)
    }
}

/// A big number field as in Loop's carb and bolus screens, keeping the shared field's limits.
struct BigAmountRow: View {
    let label: String
    var labelWeight: Font.Weight = .regular
    @Binding var quantity: HKQuantity
    let unit: HKUnit
    let unitText: String
    let color: UIColor
    let maxLength: Int
    let minValue: HKQuantity
    let maxValue: HKQuantity
    var isFocused: FocusState<Bool>.Binding
    let onValidationError: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .fontWeight(labelWeight)
            Spacer()
            TextFieldWithToolBar(
                quantity: $quantity,
                textColor: color,
                font: UIFont.systemFont(ofSize: 30, weight: .bold),
                maxLength: maxLength,
                unit: unit,
                minValue: minValue,
                maxValue: maxValue,
                onValidationError: onValidationError
            )
            .focused(isFocused)
            .frame(minWidth: 60, maxWidth: 140)
            .fixedSize(horizontal: false, vertical: true)
            Text(unitText)
                .font(.title3.weight(.semibold))
                .foregroundColor(Color(color))
        }
        .padding(.vertical, 4)
    }
}

/// The line under the bolus that says what Loop does with it.
struct DoseSafetyNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundColor(.blue)
        }
    }
}

/// A row with a name on the left and a value on the right, as in the sketches.
struct DoseInfoRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            value()
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The doses someone else gave in the last half hour, from `DoseGuard`, in red.
struct DosesFromElsewhereSection: View {
    let doses: [LoggedDose]

    var body: some View {
        if !doses.isEmpty {
            Section(
                header: Label(DoseGuardText.sectionTitle, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red),
                footer: Text(DoseGuardText.sectionFooter)
            ) {
                ForEach(doses, id: \.date) { dose in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DoseGuardText.sentence(dose))
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.red)
                        Text(DoseGuardText.minutesAgo(dose.date, now: Date()))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

/// Clears the one-time code's «used» mark when a new code period starts, as the old screens did
/// with their visible countdown. The code itself is no longer shown; it is added when needed.
struct TOTPPeriodWatcher: ViewModifier {
    @State private var remaining: Int?
    private let period: TimeInterval = 30
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content.onReceive(timer) { _ in
            let now = Date().timeIntervalSince1970
            let newRemaining = Int(period - now.truncatingRemainder(dividingBy: period))
            if let remaining, newRemaining > remaining {
                TOTPService.shared.resetTOTPUsage()
            }
            if newRemaining >= 29 {
                TOTPService.shared.resetTOTPUsage()
            }
            remaining = newRemaining
        }
    }
}

/// The one-time code was used for the last command and the next one is not there yet.
struct TOTPBlockedSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("TOTP Code Already Used")
                        .font(.headline)
                        .foregroundColor(.orange)
                }
                Text("This TOTP code has already been used for a command. Please wait for the next code to be generated before sending another command.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 4)
        }
    }
}
