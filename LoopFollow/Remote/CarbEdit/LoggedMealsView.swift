// LoopFollow
// LoggedMealsView.swift

import HealthKit
import SwiftUI

/// The words on the logged-meals screens, in their own table (CarbEdit.xcstrings).
enum CarbEditText {
    static func time(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle().hour().minute())
        }
        return date.formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute())
    }

    static func grams(_ grams: Double) -> String {
        Localizer.formatToLocalizedString(grams, maxFractionDigits: 1) + " g"
    }

    static func hours(_ hours: Double) -> String {
        String(format: String(localized: "%@ h", table: "CarbEdit", comment: "Absorption time in hours (1: number of hours)"), Localizer.formatToLocalizedString(hours, maxFractionDigits: 1))
    }

    /// "🍕 Pizza", or "Carbs" when the entry has no food type.
    static func title(_ foodType: String?) -> String {
        CarbFoodLabel(foodType: foodType).foodType ?? String(localized: "Carbs", table: "CarbEdit", comment: "Title of a logged meal without emoji or name")
    }

    static func waiting(since date: Date) -> String {
        String(format: String(localized: "Sent %@ – waiting for Loop", table: "CarbEdit", comment: "A change to a meal was sent from this phone (1: time)"), date.formatted(Date.FormatStyle().hour().minute()))
    }
}

/// Loop's meals from the last day; tap one to change or delete it.
struct LoggedMealsView: View {
    @ObservedObject private var store = LoggedCarbsStore.shared

    var body: some View {
        List {
            Section(footer: Text(String(localized: "Only meals logged in Loop – also those sent from here – can be changed. Loop makes the change and uploads it to Nightscout; the chart follows shortly after.", table: "CarbEdit", comment: "Footer of the logged meals list"))) {
                if store.entries.isEmpty {
                    Text(String(localized: "No meals from Loop in the last 24 hours.", table: "CarbEdit", comment: "Empty logged meals list"))
                        .foregroundColor(.secondary)
                }
                ForEach(store.entries) { entry in
                    NavigationLink(destination: CarbEditView(entry: entry)) {
                        row(for: entry)
                    }
                }
            }
        }
        .navigationBarTitle(String(localized: "Logged Meals", table: "CarbEdit", comment: "Title of the logged meals list"), displayMode: .inline)
    }

    private func row(for entry: LoggedCarbEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(CarbEditText.title(entry.foodType))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(CarbEditText.grams(entry.grams))
                    .font(.body.monospacedDigit())
            }
            HStack {
                Text(CarbEditText.time(entry.date))
                if let minutes = entry.absorptionMinutes {
                    Text("·")
                    Text(CarbEditText.hours(minutes / 60))
                }
                Spacer()
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            if let sentAt = store.sentAt(entry) {
                Text(CarbEditText.waiting(since: sentAt))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Changes one meal's carbs, time, absorption or food, or deletes it, through Loop's remote commands.
struct CarbEditView: View {
    let entry: LoggedCarbEntry

    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var store = LoggedCarbsStore.shared
    @State private var draft: CarbEditDraft
    @State private var carbsAmount: HKQuantity
    @State private var isSending = false
    @State private var alert: AlertKind?
    @FocusState private var carbsFieldIsFocused: Bool

    private let emojiChoices = ["🍭", "🌮", "🍕", "🍽️"]
    private let maxPastHours = 12.0
    private let maxFutureHours = 1.0

    private enum AlertKind: Identifiable {
        case confirmSave
        case confirmDelete
        case sent(String)
        case error(String)

        var id: String {
            switch self {
            case .confirmSave: return "confirmSave"
            case .confirmDelete: return "confirmDelete"
            case .sent: return "sent"
            case .error: return "error"
            }
        }
    }

    init(entry: LoggedCarbEntry) {
        self.entry = entry
        _draft = State(initialValue: CarbEditDraft(entry: entry))
        _carbsAmount = State(initialValue: HKQuantity(unit: .gram(), doubleValue: entry.grams))
    }

    /// Loop places a moved meal only where a new one may go, so the time can be changed only then.
    private var timeRange: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-maxPastHours * 3600) ... now.addingTimeInterval(maxFutureHours * 3600)
    }

    private var canMove: Bool {
        timeRange.contains(entry.date)
    }

    private var editedDraft: CarbEditDraft {
        var edited = draft
        edited.grams = carbsAmount.doubleValue(for: .gram())
        return edited
    }

    private var changes: [String: Any]? {
        editedDraft.changes(from: entry)
    }

    private var emojiOptions: [String] {
        let original = CarbFoodLabel(foodType: entry.foodType).emoji
        return original.isEmpty || emojiChoices.contains(original) ? emojiChoices : [original] + emojiChoices
    }

    var body: some View {
        Form {
            Section {
                HKQuantityInputView(
                    label: String(localized: "Carbs Amount", table: "CarbEdit", comment: "Label of the carbs field"),
                    quantity: $carbsAmount,
                    unit: .gram(),
                    maxLength: 4,
                    minValue: HKQuantity(unit: .gram(), doubleValue: 1.0),
                    maxValue: Storage.shared.maxCarbs.value,
                    isFocused: $carbsFieldIsFocused,
                    onValidationError: { message in
                        alert = .error(message)
                    }
                )

                if canMove {
                    DatePicker(
                        String(localized: "Time", table: "CarbEdit", comment: "Label of the meal time"),
                        selection: $draft.date,
                        in: timeRange,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } else {
                    HStack {
                        Text(String(localized: "Time", table: "CarbEdit", comment: "Label of the meal time"))
                        Spacer()
                        Text(CarbEditText.time(entry.date))
                            .foregroundColor(.secondary)
                    }
                }

                Stepper(value: $draft.absorptionHours, in: 0.5 ... 8, step: 0.5) {
                    HStack {
                        Text(String(localized: "Absorption Time", table: "CarbEdit", comment: "Label of the absorption time"))
                        Spacer()
                        Text(CarbEditText.hours(draft.absorptionHours))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Text(String(localized: "Food Type", table: "CarbEdit", comment: "Label of the emoji choice"))
                    Spacer()
                    ForEach(emojiOptions, id: \.self) { emoji in
                        Button {
                            draft.emoji = draft.emoji == emoji ? "" : emoji
                        } label: {
                            Text(emoji)
                                .font(.title3)
                                .frame(width: 42, height: 42)
                                .background(draft.emoji == emoji ? Color.white.opacity(0.12) : Color.clear)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField(String(localized: "Name (optional)", table: "CarbEdit", comment: "Placeholder of the meal name field"), text: $draft.name)
            } footer: {
                if !canMove {
                    Text(String(localized: "The meal is more than 12 hours old, so Loop will not move it. Carbs, absorption and food can still be changed.", table: "CarbEdit", comment: "Footer when the meal is too old to move"))
                }
            }

            if let sentAt = store.sentAt(entry) {
                Section {
                    Text(CarbEditText.waiting(since: sentAt))
                        .foregroundColor(.orange)
                }
            }

            Section {
                Button(role: .destructive) {
                    alert = .confirmDelete
                } label: {
                    Text(String(localized: "Delete Meal", table: "CarbEdit", comment: "Button that deletes the meal"))
                }
                .disabled(isSending)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if let problem = SendProblem.current() {
                    alert = .error(problem)
                } else {
                    alert = .confirmSave
                }
            } label: {
                Group {
                    if isSending {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(String(localized: "Sending...", table: "CarbEdit", comment: "Shown while the change is sent"))
                        }
                    } else {
                        Text(String(localized: "Save Changes", table: "CarbEdit", comment: "Button that sends the change"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(changes == nil || isSending || carbsAmount.doubleValue(for: .gram()) <= 0)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationBarTitle(CarbEditText.title(entry.foodType), displayMode: .inline)
        .alert(item: $alert) { kind in
            switch kind {
            case .confirmSave:
                return Alert(
                    title: Text(String(localized: "Change Meal?", table: "CarbEdit", comment: "Title of the confirmation before sending a change")),
                    message: Text(summary(of: editedDraft)),
                    primaryButton: .default(Text(String(localized: "Send", table: "CarbEdit", comment: "Confirms sending the change"))) {
                        send(changes, alert: String(format: String(localized: "Remote Carbs Changed: %@", table: "CarbEdit", comment: "Push alert on Loop's phone (1: new grams)"), CarbEditText.grams(editedDraft.grams)))
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete:
                return Alert(
                    title: Text(String(localized: "Delete Meal?", table: "CarbEdit", comment: "Title of the confirmation before deleting")),
                    message: Text(String(format: String(localized: "%1$@ (%2$@ at %3$@) is removed from Loop, and Loop stops counting these carbs.", table: "CarbEdit", comment: "Confirmation before deleting a meal (1: title)(2: grams)(3: time)"), CarbEditText.title(entry.foodType), CarbEditText.grams(entry.grams), CarbEditText.time(entry.date))),
                    primaryButton: .destructive(Text(String(localized: "Delete", table: "CarbEdit", comment: "Confirms deleting the meal"))) {
                        if let problem = SendProblem.current() {
                            DispatchQueue.main.async { alert = .error(problem) }
                        } else {
                            send(CarbEditDraft.deletion(of: entry), alert: String(localized: "Remote Carbs Deleted", table: "CarbEdit", comment: "Push alert on Loop's phone when a meal is deleted"))
                        }
                    },
                    secondaryButton: .cancel()
                )
            case let .sent(message):
                return Alert(
                    title: Text(String(localized: "Sent", table: "CarbEdit", comment: "Title after the change was sent")),
                    message: Text(message),
                    dismissButton: .default(Text("OK")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                )
            case let .error(message):
                return Alert(
                    title: Text(String(localized: "Error", table: "CarbEdit", comment: "Title of an error")),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func summary(of draft: CarbEditDraft) -> String {
        var parts = [CarbEditText.grams(draft.grams), CarbEditText.time(draft.date), CarbEditText.hours(draft.absorptionHours)]
        if let foodType = draft.foodType {
            parts.insert(foodType, at: 0)
        }
        return parts.joined(separator: " · ")
    }

    private func send(_ block: [String: Any]?, alert pushAlert: String) {
        guard var block else { return }
        guard let otp = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            alert = .error(String(localized: "Invalid QR code URL. Please re-scan the QR code in settings.", table: "CarbEdit", comment: "Error: no one-time code"))
            return
        }
        // Current seconds on a moved meal, so Nightscout never sees two entries in the same second.
        if block["start-time"] != nil {
            block["start-time"] = CarbEditDraft.formatDate(draft.date.dateUsingCurrentSeconds())
        }
        isSending = true
        let sentEntry = entry
        LoopAPNSService().sendCarbEditViaAPNS(carbsEdit: block, alert: pushAlert, otp: otp) { success, error in
            DispatchQueue.main.async {
                isSending = false
                if success {
                    TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                    store.markSent(sentEntry)
                    LogManager.shared.log(category: .apns, message: "Carb edit sent for \(sentEntry.grams)g at \(sentEntry.date)")
                    alert = .sent(String(localized: "Loop makes the change and shows a notification. The chart updates once Loop has uploaded it to Nightscout.", table: "CarbEdit", comment: "Message after the change was sent"))
                } else {
                    LogManager.shared.log(category: .apns, message: "Failed to send carb edit: \(error ?? "unknown error")")
                    alert = .error(error ?? String(localized: "Failed to send the change. Check your Loop APNS configuration.", table: "CarbEdit", comment: "Error: sending failed without a reason"))
                }
            }
        }
    }
}

/// Why a change can't be sent right now, or nil.
private enum SendProblem {
    static func current() -> String? {
        if !LoopAPNSService().validateSetup() {
            return String(localized: "Loop APNS setup is incomplete. Please configure all required fields in settings.", table: "CarbEdit", comment: "Error: remote commands are not set up")
        }
        if TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value) {
            return String(localized: "This one-time code was just used. Try again in a few seconds.", table: "CarbEdit", comment: "Error: the TOTP code was already used for a command")
        }
        return nil
    }
}
