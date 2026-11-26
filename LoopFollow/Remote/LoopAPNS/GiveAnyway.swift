// LoopFollow
// GiveAnyway.swift

import Foundation
import SwiftUI

/// «Give anyway» on a bolus or meal that Loop stopped, could not give, or cut down.
///
/// Loop's checks are careful on purpose, but they are often wrong about what the caregiver can see
/// (Julia, 26 November 2026: «Ofte er vurderingen feil, og da er det irriterende å ikke få
/// registrert likevel»). After reading what Loop said, the caregiver can send it again on purpose:
/// - stopped because someone else had given a dose: the same again, now claiming to know of it;
/// - not given (the pump was busy with Loop's own bolus) or never reached Loop: the same again;
/// - a meal whose carbs were saved but whose bolus was not given: the bolus alone;
/// - a meal bolus Loop cut to its own recommendation: the rest, up to what was approved.
/// A meal sent again gives what was approved, not the smaller of it and Loop's recommendation.
/// Loop still never gives more than its maximum bolus.
enum GiveAnyway {
    enum Action: Equatable {
        case bolus(units: Double)
        case meal(MealBolusRequest)

        var units: Double {
            switch self {
            case let .bolus(units): return units
            case let .meal(request): return request.bolus
            }
        }
    }

    /// Offered this long after sending; later the graph has moved on.
    static let offeredFor: TimeInterval = 30 * 60
    static let smallest = MealBolusEstimate.step

    static func action(for command: QueuedRemoteCommand, now: Date) -> Action? {
        guard let units = command.units, units > 0,
              now.timeIntervalSince(command.sentAt) < offeredFor
        else { return nil }
        let phase = command.phase(now: now)
        if let meal = command.meal {
            switch phase {
            case .stopped, .failed, .rejected, .lapsed:
                if meal.carbsSaved == true { return bolus(meal.approvedUnits) }
                return .meal(MealBolusRequest(
                    carbs: meal.carbs,
                    absorptionHours: meal.absorptionHours ?? 3,
                    foodType: meal.foodType,
                    startTime: meal.startTime ?? command.sentAt,
                    bolus: meal.approvedUnits,
                    followsRecommendation: false
                ))
            case .carbsSavedBolusFailed:
                return bolus(meal.approvedUnits)
            case .given, .savedWithoutBolus:
                // Loop gave less than approved: its recommendation with the meal was lower.
                guard let delivered = meal.deliveredUnits else { return nil }
                return bolus(meal.approvedUnits - delivered)
            default:
                return nil
            }
        }
        switch phase {
        case .stopped, .failed, .rejected, .lapsed:
            return bolus(units)
        default:
            return nil
        }
    }

    private static func bolus(_ units: Double) -> Action? {
        let rounded = MealBolusEstimate.roundedDown(units + 0.001)
        return rounded >= smallest ? .bolus(units: rounded) : nil
    }

    /// Whether the action gives only part of what was approved for a meal (Loop gave the rest).
    static func isRest(_ action: Action, of command: QueuedRemoteCommand, now: Date) -> Bool {
        guard case .bolus = action, let meal = command.meal else { return false }
        let phase = command.phase(now: now)
        return (phase == .given || phase == .savedWithoutBolus) && (meal.deliveredUnits ?? 0) > 0
    }

    // MARK: Sending

    /// The doses someone else gave that the user is told about before giving anyway: the ones Loop
    /// named, and any other that has not been shown yet.
    static func dosesToAcknowledge(for command: QueuedRemoteCommand, guard doseGuard: DoseGuard = .shared, now: Date = Date()) -> [LoggedDose] {
        var doses = command.stoppedBy ?? []
        for dose in doseGuard.unacknowledged(now: now) where !doses.contains(where: { abs($0.date.timeIntervalSince(dose.date)) < 1 && abs($0.units - dose.units) < 0.001 }) {
            doses.append(dose)
        }
        return doses.sorted { $0.date < $1.date }
    }

    /// Sends it again. The doses are counted as seen first, so Loop does not stop it for them.
    /// The completion runs on the main queue with nil, or what went wrong.
    static func send(_ action: Action, replacing command: QueuedRemoteCommand, acknowledging doses: [LoggedDose], completion: @escaping (String?) -> Void) {
        DoseGuard.shared.acknowledge(doses)
        let service = LoopAPNSService()
        switch action {
        case let .bolus(units):
            guard let otp = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
                completion(String(localized: "Invalid QR code URL. Please re-scan the QR code in settings."))
                return
            }
            service.sendBolusViaAPNS(payload: LoopAPNSPayload(type: .bolus, bolusAmount: units, otp: otp)) { success, message in
                DispatchQueue.main.async {
                    if success {
                        QuickPickBolusesManager.shared.recordBolus(units: units)
                        TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                        RemoteCommandInbox.shared.dismiss(command)
                        completion(nil)
                    } else {
                        completion(message ?? String(localized: "Failed to send insulin. Check your Loop APNS configuration."))
                    }
                }
            }
        case let .meal(request):
            service.sendMealBolus(request) { result in
                switch result {
                case .success:
                    RemoteCommandInbox.shared.dismiss(command)
                    completion(nil)
                case let .failure(error):
                    completion(error.localizedDescription)
                }
            }
        }
    }
}

enum GiveAnywayText {
    private static func units(_ value: Double) -> String {
        RemoteCommandText.units(value)
    }

    static func button(_ action: GiveAnyway.Action, rest: Bool) -> String {
        if rest {
            return String(format: String(localized: "Give the rest, %@ U", table: "RemoteControl", comment: "Button on a meal whose bolus Loop cut down; 1: units"), units(action.units))
        }
        return String(format: String(localized: "Give %@ U anyway", table: "RemoteControl", comment: "Button on a bolus or meal Loop did not give; 1: units"), units(action.units))
    }

    static func title(_ action: GiveAnyway.Action, rest: Bool) -> String {
        switch action {
        case let .meal(request):
            return String(format: String(localized: "Send %1$@ g and %2$@ U anyway?", table: "RemoteControl", comment: "1: grams, 2: units"), RemoteCommandText.grams(request.carbs), units(request.bolus))
        case let .bolus(value):
            if rest {
                return String(format: String(localized: "Give the rest, %@ U?", table: "RemoteControl", comment: "1: units"), units(value))
            }
            return String(format: String(localized: "Give %@ U anyway?", table: "RemoteControl", comment: "1: units"), units(value))
        }
    }

    static func message(_ action: GiveAnyway.Action, doses: [LoggedDose], rest: Bool) -> String {
        var parts: [String] = []
        if !doses.isEmpty {
            parts.append(DoseGuardText.sentences(doses))
        }
        switch action {
        case .meal:
            parts.append(String(localized: "Loop saves the meal and gives the bolus you approved, not its own lower suggestion. It never gives more than the maximum bolus.", table: "RemoteControl"))
        case .bolus:
            if rest {
                parts.append(String(localized: "Loop gave less than you approved because its own calculation was lower. This gives the rest as a separate bolus.", table: "RemoteControl"))
            } else {
                parts.append(String(localized: "Loop gives it even though it stopped it before. It never gives more than the maximum bolus.", table: "RemoteControl"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static var confirm: String {
        String(localized: "Give", table: "RemoteControl", comment: "Confirms giving a bolus anyway")
    }
}

/// The «Give anyway» button for one sent command, with its confirmation; nothing when it does not apply.
struct GiveAnywayButton: View {
    let command: QueuedRemoteCommand
    let now: Date

    /// Tapped: waiting for the user to confirm.
    @State private var confirming: GiveAnyway.Action?
    @State private var acknowledging: [LoggedDose] = []
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        if let action = GiveAnyway.action(for: command, now: now) {
            let rest = GiveAnyway.isRest(action, of: command, now: now)
            Button {
                acknowledging = GiveAnyway.dosesToAcknowledge(for: command)
                confirming = action
            } label: {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView().controlSize(.mini)
                    }
                    Text(GiveAnywayText.button(action, rest: rest))
                }
                .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(sending)
            .alert(
                GiveAnywayText.title(action, rest: rest),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
            ) {
                Button(GiveAnywayText.confirm) { authenticateAndSend(action) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(GiveAnywayText.message(action, doses: acknowledging, rest: rest))
            }
            .alert(
                String(localized: "Not sent", table: "RemoteControl"),
                isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })
            ) {
                Button(String(localized: "OK")) {}
            } message: {
                Text(sendError ?? "")
            }
        }
    }

    private func authenticateAndSend(_ action: GiveAnyway.Action) {
        AuthService.authenticate(reason: String(localized: "Confirm your identity to send insulin.")) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    sending = true
                    GiveAnyway.send(action, replacing: command, acknowledging: acknowledging) { error in
                        sending = false
                        sendError = error
                    }
                case let .unavailable(message):
                    sendError = message
                case .failed:
                    sendError = String(localized: "Authentication failed")
                case .canceled:
                    break
                }
            }
        }
    }
}
