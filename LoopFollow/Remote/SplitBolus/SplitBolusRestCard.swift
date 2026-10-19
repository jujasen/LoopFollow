// LoopFollow
// SplitBolusRestCard.swift

import SwiftUI

/// The words on the card, in their own table (SplitBolusRest.xcstrings).
enum SplitBolusRestText {
    static func time(_ interval: TimeInterval) -> String {
        Date(timeIntervalSince1970: interval).formatted(Date.FormatStyle().hour().minute())
    }

    /// "✂️ Rest of 🥛🍼 Melk"
    static func title(_ rest: SplitBolusRest) -> String {
        let meal = CarbFoodLabel(foodType: rest.foodType).foodType ?? rest.mealName
        guard !meal.isEmpty else {
            return String(localized: "✂️ Rest of the bolus", table: "SplitBolusRest", comment: "Card title for the rest of a split bolus for a meal without a name")
        }
        return String(format: String(localized: "✂️ Rest of %@", table: "SplitBolusRest", comment: "Card title for the rest of a split bolus (1: emoji and name of the meal)"), meal)
    }

    /// "6 g · about 0.4 U"
    static func amount(_ rest: SplitBolusRest) -> String {
        let grams = Localizer.formatToLocalizedString(rest.grams, maxFractionDigits: 1) + " g"
        guard let units = rest.units else { return grams }
        let insulin = Localizer.formatToLocalizedString(units, maxFractionDigits: 2) + " " + DeviceStatusFormat.unitsSymbol
        return String(format: String(localized: "%1$@ · about %2$@", table: "SplitBolusRest", comment: "Carbs and rough insulin of the rest of a split bolus (1: grams)(2: units)"), grams, insulin)
    }

    static func status(_ rest: SplitBolusRest, sentAt: Date?) -> String {
        if let sentAt {
            return String(format: String(localized: "Sent %@ – waiting for Loop", table: "SplitBolusRest", comment: "The rest of a split bolus was sent from this phone (1: time)"), sentAt.formatted(Date.FormatStyle().hour().minute()))
        }
        switch rest.state {
        case .due:
            return String(format: String(localized: "Due since %@", table: "SplitBolusRest", comment: "The rest of a split bolus is due (1: time)"), time(rest.dueDate))
        case .postponed:
            return String(format: String(localized: "Glucose low or falling – checked again %@", table: "SplitBolusRest", comment: "Loop held the rest of a split bolus back (1: time of the next check)"), time(rest.dueDate))
        case .waiting:
            return String(format: String(localized: "Due about %@", table: "SplitBolusRest", comment: "The rest of a split bolus is not due yet (1: time)"), time(rest.dueDate))
        }
    }

    /// What the confirmation says, including why it may be too early.
    static func confirmation(_ rest: SplitBolusRest) -> String {
        let hours = Localizer.formatToLocalizedString(Double(rest.absorptionTime) / 60, maxFractionDigits: 1)
        var text = String(
            format: String(localized: "Sends %1$@ g as “%2$@” with %3$@ h absorption. Loop doses for it like other remote carbs.", table: "SplitBolusRest", comment: "Confirmation before sending the rest of a split bolus (1: grams)(2: food type)(3: absorption hours)"),
            Localizer.formatToLocalizedString(rest.grams, maxFractionDigits: 1), rest.restFoodType, hours
        )
        switch rest.state {
        case .due:
            break
        case .postponed:
            text += "\n\n" + String(localized: "Loop held it back: glucose was low or falling.", table: "SplitBolusRest", comment: "Warning when sending a rest Loop held back")
        case .waiting:
            text += "\n\n" + String(format: String(localized: "It is not due until %@.", table: "SplitBolusRest", comment: "Warning when sending a rest early (1: time)"), time(rest.dueDate))
        }
        return text
    }
}

/// The rests waiting on Loop's phone, on the main screen, with a button that logs one from here
/// as a remote carb entry.
struct SplitBolusRestCard: View {
    @ObservedObject var store = SplitBolusRestStore.shared
    @ObservedObject private var remoteType = Storage.shared.remoteType
    @ObservedObject private var device = Storage.shared.device

    var body: some View {
        if !store.rests.isEmpty {
            VStack(spacing: 6) {
                ForEach(store.rests) { rest in
                    SplitBolusRestRow(rest: rest, canSend: remoteType.value == .loopAPNS && device.value == "Loop")
                }
            }
        }
    }
}

private struct SplitBolusRestRow: View {
    let rest: SplitBolusRest
    let canSend: Bool
    @ObservedObject private var store = SplitBolusRestStore.shared

    @State private var confirming = false
    @State private var isSending = false
    /// Why the last send failed, shown on the card until the next try.
    @State private var errorMessage: String?

    var body: some View {
        // Redrawn every half minute, so "sent" lets go of the button on time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let sentAt = store.sentAt(rest, now: context.date)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SplitBolusRestText.title(rest))
                        .font(.subheadline.weight(.semibold))
                    Text(SplitBolusRestText.amount(rest))
                        .font(.subheadline.monospacedDigit())
                    Text(SplitBolusRestText.status(rest, sentAt: sentAt))
                        .font(.caption)
                        .foregroundColor(rest.state == .postponed ? .orange : .secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                Spacer(minLength: 4)
                if canSend {
                    sendButton(sentAt: sentAt)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(rest.isDue && sentAt == nil ? 0.22 : 0.1))
            )
        }
        // An alert like the carbs screen's: a popover dialog is easy to dismiss by mistake.
        .alert(
            String(localized: "Give the rest now?", table: "SplitBolusRest", comment: "Title of the confirmation before sending the rest of a split bolus"),
            isPresented: $confirming
        ) {
            Button(String(localized: "Cancel", table: "SplitBolusRest", comment: "Button that closes the confirmation without sending"), role: .cancel) {}
            Button(String(localized: "Send", table: "SplitBolusRest", comment: "Button that sends the rest of a split bolus")) { send() }
        } message: {
            Text(SplitBolusRestText.confirmation(rest))
        }
    }

    @ViewBuilder
    private func sendButton(sentAt: Date?) -> some View {
        let title = sentAt != nil
            ? String(localized: "Sent", table: "SplitBolusRest", comment: "Button while the rest of a split bolus sent from here waits for Loop")
            : store.sent[rest.id] != nil
            ? String(localized: "Send again", table: "SplitBolusRest", comment: "Button to send the rest of a split bolus again when Loop never got it")
            : String(localized: "Give the rest", table: "SplitBolusRest", comment: "Button that logs the rest of a split bolus from LoopFollow")
        Group {
            if isSending {
                ProgressView()
            } else if rest.isDue && sentAt == nil {
                Button(title) { confirming = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title) { confirming = true }
                    .buttonStyle(.bordered)
            }
        }
        .tint(.orange)
        .disabled(sentAt != nil || isSending)
    }

    private func send() {
        errorMessage = nil
        if let problem = SplitBolusRestSender.problem(with: rest) {
            LogManager.shared.log(category: .apns, message: "Split bolus rest not sent: \(problem)")
            errorMessage = problem
            return
        }
        isSending = true
        SplitBolusRestSender.send(rest) { error in
            isSending = false
            if let error {
                errorMessage = error
            } else {
                store.markSent(rest)
            }
        }
    }
}

/// Sends the rest through Loop's remote commands, the way the carbs screen sends a meal.
enum SplitBolusRestSender {
    /// Why the rest can't be sent right now, or nil.
    static func problem(with rest: SplitBolusRest, maxCarbs: Double = Storage.shared.maxCarbs.value.doubleValue(for: .gram())) -> String? {
        if rest.grams > maxCarbs {
            return String(format: String(localized: "The rest (%1$@ g) is more than the maximum carbs allowed (%2$@ g).", table: "SplitBolusRest", comment: "Error: the rest of a split bolus exceeds the carb guardrail (1: grams)(2: maximum)"),
                          Localizer.formatToLocalizedString(rest.grams, maxFractionDigits: 1), Localizer.formatToLocalizedString(maxCarbs, maxFractionDigits: 0))
        }
        if !LoopAPNSService().validateSetup() {
            return String(localized: "Loop APNS setup is incomplete. Please configure all required fields in settings.", table: "SplitBolusRest", comment: "Error: remote commands are not set up")
        }
        if TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value) {
            return String(localized: "This one-time code was just used. Try again in a few seconds.", table: "SplitBolusRest", comment: "Error: the TOTP code was already used for a command")
        }
        return nil
    }

    static func send(_ rest: SplitBolusRest, completion: @escaping (String?) -> Void) {
        guard let otp = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            completion(String(localized: "Invalid QR code URL. Please re-scan the QR code in settings.", table: "SplitBolusRest", comment: "Error: no one-time code"))
            return
        }
        // Current seconds, so Nightscout never sees two entries in the same second.
        let payload = rest.payload(otp: otp, at: Date().dateUsingCurrentSeconds())
        LoopAPNSService().sendCarbsViaAPNS(payload: payload) { success, error in
            DispatchQueue.main.async {
                if success {
                    TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                    LogManager.shared.log(category: .apns, message: "Split bolus rest sent: \(rest.grams)g \(rest.restFoodType)")
                    completion(nil)
                } else {
                    LogManager.shared.log(category: .apns, message: "Failed to send split bolus rest: \(error ?? "unknown error")")
                    completion(error ?? String(localized: "Failed to send carbs. Check your Loop APNS configuration.", table: "SplitBolusRest", comment: "Error: sending failed without a reason"))
                }
            }
        }
    }
}
