// LoopFollow
// LoopAPNSBolusView.swift

import HealthKit
import LocalAuthentication
import SwiftUI

struct LoopAPNSBolusView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var insulinAmount = HKQuantity(unit: .internationalUnit(), doubleValue: 0.0)
    @State private var isLoading = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var alertType: AlertType = .success

    @ObservedObject private var inbox = RemoteCommandInbox.shared
    @ObservedObject private var doseGuard = DoseGuard.shared
    /// The doses from someone else the alert is asking about.
    @State private var dosesAskedAbout: [LoggedDose] = []
    @FocusState private var insulinFieldIsFocused: Bool

    // Add state for recommended bolus and warning
    @State private var recommendedBolus: Double? = nil
    @State private var lastLoopTime: TimeInterval? = nil
    @State private var otpTimeRemaining: Int? = nil
    @State private var showOldCalculationWarning = false
    @State private var showTOTPWarning = false
    private let otpPeriod: TimeInterval = 30
    private var otpTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// An amount to start from, such as an AI suggestion; it can be changed before sending.
    private let prefilledUnits: Double?
    /// Called once the bolus has been sent.
    private let onSent: (() -> Void)?
    @State private var didPrefill = false

    init(prefilledUnits: Double? = nil, onSent: (() -> Void)? = nil) {
        self.prefilledUnits = prefilledUnits
        self.onSent = onSent
    }

    // Computed property to check if TOTP should be blocked
    private var isTOTPBlocked: Bool {
        TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
    }

    enum AlertType {
        case success
        case error
        case confirmation
        case oldCalculationWarning
        /// An earlier bolus may still be given: a second one could come on top of it.
        case bolusOnTheWay
        /// Someone else gave a dose in the last half hour.
        case doseFromElsewhere
    }

    var body: some View {
        NavigationView {
            Form {
                let chart = RemoteDoseContext.chartData()
                if !chart.prediction.isEmpty {
                    Section {
                        PredictionMiniChart(
                            title: String(localized: "Prediction without bolus", table: "MealBolus"),
                            history: chart.history,
                            prediction: chart.prediction
                        )
                    }
                }

                // Doses someone else gave in the last half hour: on the phone with Loop, by the
                // evening watch or from another LoopFollow.
                // (The one-second timer below redraws this, so the minutes stay current.)
                DosesFromElsewhereSection(doses: doseGuard.fromElsewhere(commands: inbox.commands))

                // What became of the last bolus sent from here
                if let last = inbox.visible().first(where: \.isBolus) {
                    Section {
                        RemoteCommandRow(command: last)
                    }
                }

                Section {
                    DoseInfoRow(title: String(localized: "Glucose", table: "MealBolus")) {
                        Text(RemoteDoseContext.glucoseText() ?? "–")
                    }
                    DoseInfoRow(title: String(localized: "Active insulin", table: "MealBolus")) {
                        Text(RemoteDoseContext.insulinOnBoard.map(RemoteDoseContext.units) ?? "–")
                    }
                    DoseInfoRow(title: String(localized: "Last bolus", table: "MealBolus")) {
                        if let last = RemoteDoseContext.lastBolus {
                            Text(String(format: String(localized: "%@ at %@", table: "MealBolus", comment: "1: units, 2: time"), RemoteDoseContext.units(last.units), RemoteDoseContext.time(last.date)))
                        } else {
                            Text("–")
                        }
                    }
                }

                Section {
                    recommendedBolusRow

                    BigAmountRow(
                        label: String(localized: "Bolus", table: "MealBolus"),
                        labelWeight: .semibold,
                        quantity: $insulinAmount,
                        unit: .internationalUnit(),
                        unitText: String(localized: "U", table: "MealBolus", comment: "Insulin unit after the bolus field"),
                        color: .systemOrange,
                        maxLength: 5,
                        minValue: HKQuantity(unit: .internationalUnit(), doubleValue: 0.025),
                        maxValue: Storage.shared.maxBolus.value,
                        isFocused: $insulinFieldIsFocused,
                        onValidationError: { message in
                            alertMessage = message
                            alertType = .error
                            showAlert = true
                        }
                    )
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        // Warning for the recommended bolus's age
                        if recommendedBolus != nil, let lastLoopTime {
                            let timeSinceCalculation = Date().timeIntervalSince1970 - lastLoopTime
                            let minutesSinceCalculation = Int(timeSinceCalculation / 60)
                            if minutesSinceCalculation < 12 {
                                Text("WARNING: New treatments may have occurred since the last recommended bolus was calculated \(presentableMinutesFormat(timeInterval: timeSinceCalculation)) ago.")
                                    .foregroundColor(minutesSinceCalculation >= 5 ? .red : .orange)
                            }
                        }
                        DoseSafetyNote(text: safetyText)
                    }
                    .padding(.top, 6)
                }

                // TOTP Blocking Warning Section
                if isTOTPBlocked && showTOTPWarning {
                    TOTPBlockedSection()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: sendInsulin) {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Sending...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Deliver bolus", tableName: "MealBolus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(insulinAmount.doubleValue(for: .internationalUnit()) <= 0 || isLoading || isTOTPBlocked)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle(Text("Bolus", tableName: "MealBolus"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "MealBolus")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }

            .onAppear {
                // Validate APNS setup
                let apnsService = LoopAPNSService()
                if !apnsService.validateSetup() {
                    alertMessage = String(localized: "Loop APNS setup is incomplete. Please configure all required fields in settings.")
                    alertType = .error
                    showAlert = true
                }

                // Fresh treatments: a dose someone just gave on the phone with Loop must show here.
                TaskScheduler.shared.rescheduleTask(id: .treatments, to: Date())

                loadRecommendedBolus()
                if !didPrefill, let prefilledUnits, prefilledUnits > 0 {
                    didPrefill = true
                    insulinAmount = HKQuantity(unit: .internationalUnit(), doubleValue: prefilledUnits)
                }
                // Reset timer state so it shows '-' until first tick
                otpTimeRemaining = nil
                // Don't reset TOTP usage flag here - let the timer handle it

                // Validate TOTP state when view appears
                _ = isTOTPBlocked

                // Add delay before showing TOTP warning to prevent flash after successful send
                if isTOTPBlocked {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showTOTPWarning = true
                    }
                } else {
                    showTOTPWarning = false
                }
            }
            .onReceive(otpTimer) { _ in
                let now = Date().timeIntervalSince1970
                let newOtpTimeRemaining = Int(otpPeriod - (now.truncatingRemainder(dividingBy: otpPeriod)))

                // Check if we've moved to a new TOTP period (when time remaining increases)
                if let currentOtpTimeRemaining = otpTimeRemaining,
                   newOtpTimeRemaining > currentOtpTimeRemaining
                {
                    // New TOTP code generated, reset the usage flag
                    TOTPService.shared.resetTOTPUsage()
                }

                // Also check if we're at the very beginning of a new period (when time remaining is close to 30)
                if newOtpTimeRemaining >= 29 {
                    // We're at the start of a new TOTP period, reset the usage flag
                    TOTPService.shared.resetTOTPUsage()
                }

                otpTimeRemaining = newOtpTimeRemaining

                // Check if recommended bolus calculation is older than 5 minutes (but less than 12 minutes)
                if let lastLoopTime = lastLoopTime {
                    let timeSinceCalculation = now - lastLoopTime
                    let minutesSinceCalculation = Int(timeSinceCalculation / 60)

                    // Only show warning if calculation is between 5-12 minutes old
                    if minutesSinceCalculation > 5 && minutesSinceCalculation < 12 && !showOldCalculationWarning {
                        showOldCalculationWarning = true
                        alertMessage = String(localized: "This recommended bolus was calculated \(minutesSinceCalculation) minutes ago. New treatments may have occurred since then. Proceed with caution.")
                        alertType = .oldCalculationWarning
                        showAlert = true
                    }
                }
            }
            .alert(isPresented: $showAlert) {
                switch alertType {
                case .success:
                    return Alert(
                        title: Text("Command Sent"),
                        message: Text(alertMessage),
                        dismissButton: .default(Text("OK")) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    )
                case .error:
                    return Alert(
                        title: Text("Error"),
                        message: Text(alertMessage),
                        dismissButton: .default(Text("OK"))
                    )
                case .confirmation:
                    return Alert(
                        title: Text("Confirm Insulin"),
                        message: Text("Send \(Localizer.formatToLocalizedString(insulinAmount.doubleValue(for: .internationalUnit()), maxFractionDigits: 2, minFractionDigits: 2)) units of insulin?"),
                        primaryButton: .default(Text("Send")) {
                            authenticateAndSendInsulin()
                        },
                        secondaryButton: .cancel()
                    )
                case .bolusOnTheWay:
                    return Alert(
                        title: Text(String(localized: "A bolus is already on its way", table: "RemoteCommandInbox")),
                        message: Text(alertMessage),
                        primaryButton: .destructive(Text(String(localized: "Send anyway", table: "RemoteCommandInbox"))) {
                            authenticateAndSendInsulin()
                        },
                        secondaryButton: .cancel(Text(String(localized: "Don't send", table: "RemoteCommandInbox")))
                    )
                case .doseFromElsewhere:
                    return Alert(
                        title: Text(DoseGuardText.alertTitle),
                        message: Text(alertMessage),
                        primaryButton: .destructive(Text(String(localized: "Send anyway", table: "RemoteCommandInbox"))) {
                            // Seen and accepted: the bolus now says it knows of these doses.
                            doseGuard.acknowledge(dosesAskedAbout)
                            authenticateAndSendInsulin()
                        },
                        secondaryButton: .cancel(Text(String(localized: "Don't send", table: "RemoteCommandInbox")))
                    )
                case .oldCalculationWarning:
                    return Alert(
                        title: Text("Old Calculation Warning"),
                        message: Text(alertMessage),
                        primaryButton: .default(Text("Use Anyway")) {
                            applyRecommendedBolus()
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
        // Pushed from the remote screen, its bar would sit above this one with a second back button.
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Loop's latest recommendation and how old it is; a tap puts it in the field.
    @ViewBuilder
    private var recommendedBolusRow: some View {
        let fresh: (units: Double, minutes: Int, at: Date)? = {
            guard let recommendedBolus, recommendedBolus > 0, let lastLoopTime else { return nil }
            let minutes = Int((Date().timeIntervalSince1970 - lastLoopTime) / 60)
            // Only offered while less than 12 minutes old
            guard minutes < 12 else { return nil }
            return (recommendedBolus, minutes, Date(timeIntervalSince1970: lastLoopTime))
        }()
        Button(action: handleRecommendedBolusTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended bolus", tableName: "MealBolus")
                        .foregroundColor(.primary)
                    Group {
                        if let fresh {
                            Text(String(format: String(localized: "Loop calculated it at %@, %@ min ago", table: "MealBolus", comment: "1: time, 2: minutes"), RemoteDoseContext.time(fresh.at), "\(fresh.minutes)"))
                        } else {
                            Text("No fresh recommendation from Loop", tableName: "MealBolus")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Text(fresh.map { RemoteDoseContext.units($0.units) } ?? "–")
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(fresh == nil)
    }

    /// What Loop does if someone else gives insulin before it gets this bolus (`DoseGuard`).
    private var safetyText: String {
        let known = doseGuard.knownDosesUntil(commands: inbox.commands)
        if Date().timeIntervalSince(known) < 6 * 60 * 60 {
            return String(format: String(localized: "If someone gives insulin after %@, Loop does not give this bolus, and you are told.", table: "MealBolus", comment: "1: time"), RemoteDoseContext.time(known))
        }
        return String(localized: "If someone gives insulin you haven't seen here, Loop does not give this bolus, and you are told.", table: "MealBolus")
    }

    private func loadRecommendedBolus() {
        // Load recommended bolus from Observable
        let recommended = RecommendedBolus.current()
        recommendedBolus = recommended?.units
        lastLoopTime = recommended?.at

        // Reset warning state when new data is loaded
        showOldCalculationWarning = false
    }

    private func handleRecommendedBolusTap() {
        guard let recommendedBolus = recommendedBolus, recommendedBolus > 0 else { return }

        // Apply the recommended bolus directly (warning is handled by timer)
        applyRecommendedBolus()
    }

    private func applyRecommendedBolus() {
        guard let recommendedBolus = recommendedBolus, recommendedBolus > 0 else { return }
        insulinAmount = HKQuantity(unit: .internationalUnit(), doubleValue: recommendedBolus)
    }

    private func presentableMinutesFormat(timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval / 60)
        return minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes")
    }

    private func sendInsulin() {
        guard insulinAmount.doubleValue(for: .internationalUnit()) > 0 else {
            alertMessage = String(localized: "Please enter a valid insulin amount")
            alertType = .error
            showAlert = true
            return
        }

        // Check guardrails
        let maxBolus = Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit())
        let insulinValue = insulinAmount.doubleValue(for: .internationalUnit())

        if insulinValue > maxBolus {
            alertMessage = String(localized: "Insulin amount (\(Localizer.formatToLocalizedString(insulinValue, maxFractionDigits: 2, minFractionDigits: 2))U) exceeds the maximum allowed (\(Localizer.formatToLocalizedString(maxBolus, maxFractionDigits: 2, minFractionDigits: 2))U). Please reduce the amount.")
            alertType = .error
            showAlert = true
            return
        }

        // Someone else may be correcting the same glucose. Asked once per dose; a bolus sent without
        // this (or before the dose shows here) is stopped by Loop instead.
        let unseen = doseGuard.unacknowledged()
        if !unseen.isEmpty {
            dosesAskedAbout = unseen
            alertMessage = DoseGuardText.alertMessage(unseen, sending: insulinValue)
            alertType = .doseFromElsewhere
            showAlert = true
            return
        }

        if let open = RemoteCommandInbox.shared.openBolus() {
            let units = Localizer.formatToLocalizedString(insulinValue, maxFractionDigits: 2, minFractionDigits: 0)
            alertMessage = String(format: String(localized: "%@\n\nIf you send %@ U now, both can be given. Send it anyway?", table: "RemoteCommandInbox", comment: "1: what became of the earlier bolus, 2: the new amount"), RemoteCommandText.title(open, now: Date()) + "\n" + RemoteCommandText.detail(open, now: Date()), units)
            alertType = .bolusOnTheWay
            showAlert = true
            return
        }

        alertType = .confirmation
        showAlert = true
    }

    private func authenticateAndSendInsulin() {
        AuthService.authenticate(reason: String(localized: "Confirm your identity to send insulin.")) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.sendInsulinConfirmed()
                case let .unavailable(message):
                    self.alertMessage = message
                    self.alertType = .error
                    self.showAlert = true
                case .failed:
                    self.alertMessage = String(localized: "Authentication failed")
                    self.alertType = .error
                    self.showAlert = true
                case .canceled:
                    // User canceled: no alert to avoid spammy UX
                    break
                }
            }
        }
    }

    private func sendInsulinConfirmed() {
        isLoading = true

        // Extract OTP from QR code URL
        guard let otpCode = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            alertMessage = String(localized: "Invalid QR code URL. Please re-scan the QR code in settings.")
            alertType = .error
            isLoading = false
            showAlert = true
            return
        }

        let payload = LoopAPNSPayload(
            type: .bolus,
            bolusAmount: insulinAmount.doubleValue(for: .internationalUnit()),
            otp: otpCode
        )

        let apnsService = LoopAPNSService()
        apnsService.sendBolusViaAPNS(payload: payload) { success, errorMessage in
            DispatchQueue.main.async {
                self.isLoading = false
                if success {
                    let sentUnits = insulinAmount.doubleValue(for: .internationalUnit())
                    if sentUnits > 0 {
                        QuickPickBolusesManager.shared.recordBolus(units: sentUnits)
                    }
                    // Mark TOTP code as used
                    TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                    self.onSent?()
                    self.alertMessage = RemoteCommandInbox.shared.isAvailable
                        ? String(localized: "The bolus is waiting for Loop in Nightscout. Loop fetches it within 5 minutes, or at once if the push gets through. The card on the main screen shows when it is given.", table: "RemoteCommandInbox")
                        : String(localized: "Insulin sent to Loop. Loop confirms when it is given, and LoopFollow warns you if Loop rejects it.")
                    self.alertType = .success
                    LogManager.shared.log(
                        category: .apns,
                        message: "Insulin sent - Amount: \(insulinAmount.doubleValue(for: .internationalUnit()))U"
                    )
                } else {
                    self.alertMessage = errorMessage ?? String(localized: "Failed to send insulin. Check your Loop APNS configuration.")
                    self.alertType = .error
                    LogManager.shared.log(
                        category: .apns,
                        message: "Failed to send insulin: \(errorMessage ?? "unknown error")"
                    )
                }
                self.showAlert = true
            }
        }
    }
}
