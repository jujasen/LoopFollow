// LoopFollow
// MealBolusScreen.swift

// Step 2 of «Add meal» when Loop takes a meal with bolus: what is known about the glucose and the
// insulin, LoopFollow's guess at the bolus, the most Loop may give, and «Save and deliver» or
// «Save without bolus» (the plain carb command).

import HealthKit
import SwiftUI

/// The meal as entered on the first screen.
struct MealDraft: Equatable {
    var carbs: Double
    var absorptionHours: Double
    var label: CarbFoodLabel
    var startDate: Date

    var foodType: String? { label.foodType }
}

struct MealBolusScreen: View {
    let draft: MealDraft
    /// The carb command alone, as before.
    let onSaveWithoutBolus: () -> Void
    let isSavingCarbs: Bool
    let onSent: (QueuedRemoteCommand) -> Void

    @ObservedObject private var inbox = RemoteCommandInbox.shared
    @ObservedObject private var doseGuard = DoseGuard.shared
    @ObservedObject private var recommendedBolus = Observable.shared.deviceRecBolus
    @State private var bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: 0)
    /// The estimate last put in the field; the field follows a new estimate until it is edited.
    @State private var appliedEstimate: Double?
    @State private var isSending = false
    @State private var alert: MealBolusAlert?
    @FocusState private var bolusFieldIsFocused: Bool

    private var units: Double {
        bolusAmount.doubleValue(for: .internationalUnit())
    }

    private var estimate: MealBolusEstimate? {
        _ = recommendedBolus.value
        return MealBolusEstimate.current(carbs: draft.carbs)
    }

    /// The caregiver kept the number LoopFollow suggested.
    private var followsRecommendation: Bool {
        guard let estimate else { return false }
        return abs(estimate.units - units) < 0.001
    }

    var body: some View {
        Form {
            let chart = RemoteDoseContext.chartData()
            if !chart.prediction.isEmpty {
                Section {
                    PredictionMiniChart(
                        title: String(localized: "Loop's prediction before the meal", table: "MealBolus"),
                        history: chart.history,
                        prediction: chart.prediction
                    )
                }
            }

            DosesFromElsewhereSection(doses: doseGuard.fromElsewhere(commands: inbox.commands))

            if let last = inbox.visible().first(where: \.isBolus) {
                Section {
                    RemoteCommandRow(command: last)
                }
            }

            Section {
                DoseInfoRow(title: String(localized: "Carbs", table: "MealBolus")) {
                    (Text(String(format: String(localized: "%@ g", table: "MealBolus", comment: "1: grams"), RemoteCommandText.grams(draft.carbs))).bold().foregroundColor(.green)
                        + Text(" · " + mealSummary))
                }
                DoseInfoRow(title: String(localized: "Glucose", table: "MealBolus")) {
                    Text(RemoteDoseContext.glucoseText() ?? "–")
                }
                DoseInfoRow(title: String(localized: "Active insulin", table: "MealBolus")) {
                    Text(RemoteDoseContext.insulinOnBoard.map(RemoteDoseContext.units) ?? "–")
                }
            }

            Section {
                Button(action: applyEstimate) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended bolus", tableName: "MealBolus")
                                .foregroundColor(.primary)
                            Text(estimateExplanation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(estimate.map { RemoteDoseContext.units($0.units) } ?? "–")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .disabled(estimate == nil)

                BigAmountRow(
                    label: String(localized: "Bolus", table: "MealBolus"),
                    labelWeight: .semibold,
                    quantity: $bolusAmount,
                    unit: .internationalUnit(),
                    unitText: String(localized: "U", table: "MealBolus", comment: "Insulin unit after the bolus field"),
                    color: .systemOrange,
                    maxLength: 5,
                    minValue: HKQuantity(unit: .internationalUnit(), doubleValue: 0),
                    maxValue: Storage.shared.maxBolus.value,
                    isFocused: $bolusFieldIsFocused,
                    onValidationError: { message in alert = .error(message) }
                )
            } footer: {
                if units > 0 {
                    DoseSafetyNote(text: safetyText)
                        .padding(.top, 6)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button(action: saveAndDeliver) {
                    Group {
                        if isSending {
                            HStack {
                                ProgressView()
                                Text("Sending...")
                            }
                        } else {
                            Text("Save and deliver", tableName: "MealBolus")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(units <= 0 || isSending || isSavingCarbs)

                Button(action: onSaveWithoutBolus) {
                    Group {
                        if isSavingCarbs {
                            ProgressView()
                        } else {
                            Text("Save without bolus", tableName: "MealBolus")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .disabled(isSending || isSavingCarbs)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
        }
        .onAppear {
            // Fresh treatments: a dose someone just gave on the phone with Loop must show here.
            TaskScheduler.shared.rescheduleTask(id: .treatments, to: Date())
            if appliedEstimate == nil, let estimate {
                setBolus(estimate.units)
            }
        }
        .onChange(of: estimate?.units) { _, newValue in
            // Still the suggestion: follow a newer one (Loop uploaded a recommendation meanwhile).
            guard let newValue, let appliedEstimate, abs(units - appliedEstimate) < 0.001 else { return }
            setBolus(newValue)
        }
        .alert(item: $alert) { alert in
            switch alert {
            case let .error(message):
                return Alert(title: Text("Error"), message: Text(message), dismissButton: .default(Text("OK")))
            case let .doseFromElsewhere(doses):
                return Alert(
                    title: Text(DoseGuardText.alertTitle),
                    message: Text(DoseGuardText.alertMessage(doses, sending: units)),
                    primaryButton: .destructive(Text(String(localized: "Send anyway", table: "RemoteCommandInbox"))) {
                        doseGuard.acknowledge(doses)
                        checkOpenBolusThenSend()
                    },
                    secondaryButton: .cancel(Text(String(localized: "Don't send", table: "RemoteCommandInbox")))
                )
            case let .bolusOnTheWay(message):
                return Alert(
                    title: Text(String(localized: "A bolus is already on its way", table: "RemoteCommandInbox")),
                    message: Text(message),
                    primaryButton: .destructive(Text(String(localized: "Send anyway", table: "RemoteCommandInbox"))) {
                        authenticateAndSend()
                    },
                    secondaryButton: .cancel(Text(String(localized: "Don't send", table: "RemoteCommandInbox")))
                )
            }
        }
    }

    // MARK: Texts

    /// «🍕 Pizza · nå · 4 t»
    private var mealSummary: String {
        var parts: [String] = []
        if let foodType = draft.foodType {
            parts.append(foodType)
        }
        if abs(draft.startDate.timeIntervalSinceNow) < 60 {
            parts.append(String(localized: "now", table: "MealBolus", comment: "The meal's time when it is now"))
        } else {
            parts.append(RemoteDoseContext.time(draft.startDate))
        }
        parts.append(MealAbsorption.shortText(hours: draft.absorptionHours))
        return parts.joined(separator: " · ")
    }

    private var estimateExplanation: String {
        guard let estimate else {
            return String(localized: "No estimate: LoopFollow has no carb ratio from Loop yet. Type the bolus yourself.", table: "MealBolus")
        }
        var text = String(localized: "Estimate. Loop works it out again when the meal arrives.", table: "MealBolus")
        if let at = estimate.recommendationAt {
            text += " " + String(format: String(localized: "Loop's recommendation from %@ plus %@ g ÷ %@.", table: "MealBolus", comment: "1: time, 2: grams, 3: carb ratio"), RemoteDoseContext.time(at), RemoteCommandText.grams(draft.carbs), Localizer.formatToLocalizedString(estimate.carbRatio, maxFractionDigits: 1))
        } else {
            text += " " + String(format: String(localized: "%@ g ÷ %@; Loop has no fresh recommendation to add.", table: "MealBolus", comment: "1: grams, 2: carb ratio"), RemoteCommandText.grams(draft.carbs), Localizer.formatToLocalizedString(estimate.carbRatio, maxFractionDigits: 1))
        }
        if estimate.cappedAtMax {
            text += " " + String(localized: "Limited to the maximum bolus.", table: "MealBolus")
        }
        return text
    }

    private var safetyText: String {
        let amount = RemoteDoseContext.units(MealBolusEstimate.rounded(units))
        if followsRecommendation {
            return String(format: String(localized: "Loop saves the carbs and never gives more than %@. If insulin has come since, Loop gives less. You are told when the bolus is given.", table: "MealBolus", comment: "1: units"), amount)
        }
        return String(format: String(localized: "Loop saves the carbs and gives %@, the amount you chose. If someone gave insulin you haven't seen here, Loop gives no bolus. You are told when the bolus is given.", table: "MealBolus", comment: "1: units"), amount)
    }

    // MARK: Sending

    private func setBolus(_ value: Double) {
        appliedEstimate = value
        bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: value)
    }

    private func applyEstimate() {
        guard let estimate else { return }
        bolusFieldIsFocused = false
        setBolus(estimate.units)
    }

    private func saveAndDeliver() {
        bolusFieldIsFocused = false
        guard units > 0 else { return }
        let maxBolus = MealBolusEstimate.maxBolus
        if units > maxBolus + 0.0001 {
            alert = .error(String(localized: "Insulin amount (\(Localizer.formatToLocalizedString(units, maxFractionDigits: 2, minFractionDigits: 2))U) exceeds the maximum allowed (\(Localizer.formatToLocalizedString(maxBolus, maxFractionDigits: 2, minFractionDigits: 2))U). Please reduce the amount."))
            return
        }
        // Someone else may be correcting the same glucose: asked once per dose, as on the bolus screen.
        let unseen = doseGuard.unacknowledged()
        if !unseen.isEmpty {
            alert = .doseFromElsewhere(unseen)
            return
        }
        checkOpenBolusThenSend()
    }

    private func checkOpenBolusThenSend() {
        if let open = inbox.openBolus() {
            let amount = Localizer.formatToLocalizedString(units, maxFractionDigits: 2, minFractionDigits: 0)
            alert = .bolusOnTheWay(String(format: String(localized: "%@\n\nIf you send %@ U now, both can be given. Send it anyway?", table: "RemoteCommandInbox", comment: "1: what became of the earlier bolus, 2: the new amount"), RemoteCommandText.title(open, now: Date()) + "\n" + RemoteCommandText.detail(open, now: Date()), amount))
            return
        }
        authenticateAndSend()
    }

    private func authenticateAndSend() {
        AuthService.authenticate(reason: String(localized: "Confirm your identity to send insulin.")) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    send()
                case let .unavailable(message):
                    alert = .error(message)
                case .failed:
                    alert = .error(String(localized: "Authentication failed"))
                case .canceled:
                    break
                }
            }
        }
    }

    private func send() {
        isSending = true
        let request = MealBolusRequest(
            carbs: draft.carbs,
            absorptionHours: draft.absorptionHours,
            foodType: draft.foodType,
            // Nightscout doesn't take two entries in the same second (as for the carb command).
            startTime: draft.startDate.dateUsingCurrentSeconds(),
            bolus: units,
            followsRecommendation: followsRecommendation
        )
        LoopAPNSService().sendMealBolus(request) { result in
            isSending = false
            switch result {
            case let .success(command):
                onSent(command)
            case let .failure(error):
                alert = .error(error.localizedDescription)
            }
        }
    }
}

enum MealBolusAlert: Identifiable {
    case error(String)
    case doseFromElsewhere([LoggedDose])
    case bolusOnTheWay(String)

    var id: String {
        switch self {
        case let .error(message): return "error-\(message)"
        case .doseFromElsewhere: return "doseFromElsewhere"
        case .bolusOnTheWay: return "bolusOnTheWay"
        }
    }
}

/// The three absorption speeds on the meal screen, as in the sketch Julia approved.
enum MealAbsorption: Int, CaseIterable, Identifiable {
    case fast = 120
    case medium = 180
    case slow = 240

    var id: Int { rawValue }
    var minutes: Int { rawValue }

    var title: String {
        switch self {
        case .fast: return String(localized: "Fast", table: "MealBolus", comment: "Absorption speed")
        case .medium: return String(localized: "Medium", table: "MealBolus", comment: "Absorption speed")
        case .slow: return String(localized: "Slow", table: "MealBolus", comment: "Absorption speed")
        }
    }

    var examples: String {
        switch self {
        case .fast: return String(localized: "sweets, juice", table: "MealBolus", comment: "Examples of fast carbs")
        case .medium: return String(localized: "ordinary food", table: "MealBolus", comment: "Examples of medium carbs")
        case .slow: return String(localized: "pizza, fat", table: "MealBolus", comment: "Examples of slow carbs")
        }
    }

    /// The emoji the graph shows when the meal has none of its own.
    var emoji: String {
        switch self {
        case .fast: return "🍭"
        case .medium: return "🌮"
        case .slow: return "🍕"
        }
    }

    /// «4 t», «2 t 30 min»
    static func shortText(hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if m == 0 {
            return String(format: String(localized: "%@ h", table: "MealBolus", comment: "Absorption time in whole hours"), "\(h)")
        }
        return String(format: String(localized: "%@ h %@ min", table: "MealBolus", comment: "Absorption time in hours and minutes"), "\(h)", "\(m)")
    }
}
