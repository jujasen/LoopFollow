// LoopFollow
// TherapySettingsView.swift

import HealthKit
import SwiftUI

/// Edits Loop's carb ratio and insulin sensitivity schedules from this phone. The schedules start
/// from the profile Loop last uploaded to Nightscout, and are sent back as a remote command that
/// replaces each changed schedule as a whole.
struct TherapySettingsView: View {
    @Environment(\.presentationMode) var presentationMode

    @State private var kind: TherapySettingKind = .carbRatio
    @State private var carbRatios: [TherapyScheduleEntry] = []
    @State private var sensitivities: [TherapyScheduleEntry] = []
    @State private var originalCarbRatios: [TherapyScheduleEntry] = []
    @State private var originalSensitivities: [TherapyScheduleEntry] = []
    @State private var glucoseUnit: HKUnit = .millimolesPerLiter
    @State private var loadedAt: Date?
    @State private var didLoad = false

    @State private var editing: EditedEntry?
    @State private var isLoading = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var alertType: AlertType = .error

    @State private var otpTimeRemaining: Int?
    @State private var showTOTPWarning = false
    private let otpPeriod: TimeInterval = 30
    private var otpTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isTOTPBlocked: Bool {
        TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
    }

    enum AlertType {
        case success
        case error
        case confirmation
    }

    struct EditedEntry: Identifiable {
        let kind: TherapySettingKind
        let entry: TherapyScheduleEntry
        let isNew: Bool
        var id: UUID { entry.id }
    }

    // MARK: - Derived state

    private func entries(for kind: TherapySettingKind) -> [TherapyScheduleEntry] {
        kind == .carbRatio ? carbRatios : sensitivities
    }

    private func originals(for kind: TherapySettingKind) -> [TherapyScheduleEntry] {
        kind == .carbRatio ? originalCarbRatios : originalSensitivities
    }

    private func isChanged(_ kind: TherapySettingKind) -> Bool {
        entries(for: kind) != originals(for: kind)
    }

    private var hasChanges: Bool {
        TherapySettingKind.allCases.contains(where: isChanged)
    }

    private var validationError: String? {
        for kind in TherapySettingKind.allCases where isChanged(kind) {
            do {
                try TherapySchedule.validate(entries(for: kind), kind: kind, glucoseUnit: glucoseUnit)
            } catch {
                return "\(kind.title): \(error.localizedDescription)"
            }
        }
        return nil
    }

    private var hasProfile: Bool {
        !originalCarbRatios.isEmpty || !originalSensitivities.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            Form {
                if !hasProfile {
                    Section {
                        Text("No carb ratios or insulin sensitivities have been read from Nightscout yet. They appear here once Loop's profile has loaded.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        Picker("Schedule", selection: $kind) {
                            ForEach(TherapySettingKind.allCases) { kind in
                                Text(kind.title + (isChanged(kind) ? " •" : "")).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    scheduleSection

                    if let validationError {
                        Section {
                            Label(validationError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }

                    if isTOTPBlocked && showTOTPWarning {
                        Section {
                            Text("This OTP code has already been used for a command. Wait for the next code before sending.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    Section(header: Text("Security")) {
                        HStack {
                            Text("Current OTP Code")
                            Spacer()
                            if let otpCode = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) {
                                Text(otpCode)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.green)
                                Text("(" + (otpTimeRemaining.map { "\($0)s" } ?? "-") + ")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Invalid QR code URL")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if hasProfile {
                    Button(action: confirmSend) {
                        if isLoading {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Sending...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Send to Loop")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasChanges || validationError != nil || isLoading || isTOTPBlocked)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle("Therapy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if hasChanges {
                        Button("Revert") {
                            carbRatios = originalCarbRatios
                            sensitivities = originalSensitivities
                        }
                    }
                }
            }
            .sheet(item: $editing) { edited in
                TherapyScheduleEntryEditor(
                    kind: edited.kind,
                    entry: edited.entry,
                    isNew: edited.isNew,
                    isFirst: edited.entry.start == 0 && !edited.isNew,
                    availableStarts: TherapySchedule.availableStarts(in: entries(for: edited.kind), keeping: edited.isNew ? nil : edited.entry.start),
                    glucoseUnit: glucoseUnit,
                    onSave: { save($0, kind: edited.kind) },
                    onDelete: { delete(edited.entry, kind: edited.kind) }
                )
            }
            .onAppear(perform: load)
            .onReceive(otpTimer) { _ in
                let now = Date().timeIntervalSince1970
                let remaining = Int(otpPeriod - now.truncatingRemainder(dividingBy: otpPeriod))
                if let previous = otpTimeRemaining, remaining > previous {
                    TOTPService.shared.resetTOTPUsage()
                }
                if remaining >= 29 {
                    TOTPService.shared.resetTOTPUsage()
                }
                otpTimeRemaining = remaining
                showTOTPWarning = isTOTPBlocked
            }
            .alert(isPresented: $showAlert) {
                switch alertType {
                case .success:
                    return Alert(
                        title: Text("Sent"),
                        message: Text(alertMessage),
                        dismissButton: .default(Text("OK")) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    )
                case .error:
                    return Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
                case .confirmation:
                    return Alert(
                        title: Text("Change Loop's Settings?"),
                        message: Text(alertMessage),
                        primaryButton: .destructive(Text("Send")) { authenticateAndSend() },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
    }

    private var scheduleSection: some View {
        let unitLabel = kind.unitLabel(glucoseUnit: glucoseUnit)
        let digits = kind.fractionDigits(glucoseUnit: glucoseUnit)
        let original = Dictionary(originals(for: kind).map { ($0.start, $0.value) }, uniquingKeysWith: { first, _ in first })

        return Section(
            header: Text("\(kind.title) (\(unitLabel))"),
            footer: Text(footerText)
        ) {
            ForEach(entries(for: kind)) { entry in
                Button {
                    editing = EditedEntry(kind: kind, entry: entry, isNew: false)
                } label: {
                    HStack {
                        Text(TherapySchedule.timeString(entry.start))
                            .font(.body.monospacedDigit())
                            .foregroundColor(.primary)
                        Spacer()
                        if original[entry.start] != entry.value {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.orange)
                        }
                        Text(format(entry.value, digits: digits) + " " + unitLabel)
                            .foregroundColor(.primary)
                    }
                }
                .deleteDisabled(entry.start == 0)
            }
            .onDelete { offsets in
                let current = entries(for: kind)
                for index in offsets where current[index].start != 0 {
                    delete(current[index], kind: kind)
                }
            }

            Button {
                if let entry = TherapySchedule.newEntry(after: entries(for: kind)) {
                    editing = EditedEntry(kind: kind, entry: entry, isNew: true)
                }
            } label: {
                Label("Add Time", systemImage: "plus")
            }
            .disabled(entries(for: kind).count >= TherapySchedule.maximumEntryCount)
        }
    }

    private var footerText: String {
        var text = "Each value applies from its time until the next. Tap a time to change it, swipe to remove it. Basal rates can only be changed in Loop."
        if let loadedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            text = "Read from Loop's Nightscout profile \(formatter.localizedString(for: loadedAt, relativeTo: Date())). " + text
        }
        return text
    }

    private func format(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }

    // MARK: - Editing

    /// Runs once: `onAppear` fires again when the edit sheet closes, and must not throw away edits.
    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let profile = ProfileManager.shared
        glucoseUnit = profile.units
        loadedAt = profile.loadedAt

        originalCarbRatios = TherapySchedule.rounded(TherapySchedule.entries(from: profile.carbRatioSchedule), kind: .carbRatio, glucoseUnit: glucoseUnit)
        originalSensitivities = TherapySchedule.rounded(TherapySchedule.entries(from: profile.isfSchedule, unit: glucoseUnit), kind: .insulinSensitivity, glucoseUnit: glucoseUnit)
        carbRatios = originalCarbRatios
        sensitivities = originalSensitivities

        if !LoopAPNSService().validateSetup() {
            alertMessage = "Loop APNS setup is incomplete. Please configure all required fields in settings."
            alertType = .error
            showAlert = true
        }
    }

    private func update(_ kind: TherapySettingKind, _ transform: (inout [TherapyScheduleEntry]) -> Void) {
        var entries = entries(for: kind)
        transform(&entries)
        entries = TherapySchedule.sorted(entries)
        if kind == .carbRatio {
            carbRatios = entries
        } else {
            sensitivities = entries
        }
    }

    private func save(_ entry: TherapyScheduleEntry, kind: TherapySettingKind) {
        update(kind) { entries in
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
    }

    private func delete(_ entry: TherapyScheduleEntry, kind: TherapySettingKind) {
        guard entry.start != 0 else { return }
        update(kind) { entries in entries.removeAll { $0.id == entry.id } }
    }

    // MARK: - Sending

    private func confirmSend() {
        if let validationError {
            alertMessage = validationError
            alertType = .error
            showAlert = true
            return
        }

        var lines = [String]()
        for kind in TherapySettingKind.allCases where isChanged(kind) {
            lines.append("\(kind.title) (\(kind.unitLabel(glucoseUnit: glucoseUnit))):")
            lines += TherapySchedule.changeLines(from: originals(for: kind), to: entries(for: kind), digits: kind.fractionDigits(glucoseUnit: glucoseUnit))
            lines.append("")
        }
        lines.append("Loop starts dosing with the new values right away.")
        alertMessage = lines.joined(separator: "\n")
        alertType = .confirmation
        showAlert = true
    }

    private func authenticateAndSend() {
        AuthService.authenticate(reason: "Confirm your identity to change Loop's settings.") { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.send()
                case let .unavailable(message):
                    self.alertMessage = message
                    self.alertType = .error
                    self.showAlert = true
                case .failed:
                    self.alertMessage = "Authentication failed"
                    self.alertType = .error
                    self.showAlert = true
                case .canceled:
                    break
                }
            }
        }
    }

    private func send() {
        guard let otpCode = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            alertMessage = "Invalid QR code URL. Please re-scan the QR code in settings."
            alertType = .error
            showAlert = true
            return
        }

        let therapySettings = TherapySchedule.payload(
            carbRatios: isChanged(.carbRatio) ? carbRatios : nil,
            sensitivities: isChanged(.insulinSensitivity) ? sensitivities : nil,
            glucoseUnit: glucoseUnit
        )

        isLoading = true
        LoopAPNSService().sendTherapySettingsViaAPNS(therapySettings: therapySettings, otp: otpCode) { success, errorMessage in
            DispatchQueue.main.async {
                self.isLoading = false
                if success {
                    TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                    // Loop uploads its new profile once the change is saved; read it back soon after.
                    TaskScheduler.shared.rescheduleTask(id: .profile, to: Date().addingTimeInterval(20))
                    self.alertMessage = "Loop confirms with a notification when the new settings are saved. If a value is outside what Loop allows, nothing is changed."
                    self.alertType = .success
                    LogManager.shared.log(category: .apns, message: "Therapy settings sent")
                } else {
                    self.alertMessage = errorMessage ?? "Failed to send the settings. Check your Loop APNS configuration."
                    self.alertType = .error
                    LogManager.shared.log(category: .apns, message: "Failed to send therapy settings: \(errorMessage ?? "unknown error")")
                }
                self.showAlert = true
            }
        }
    }
}

/// Edits one row: its start time (fixed at 00:00 for the first row) and its value.
private struct TherapyScheduleEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let kind: TherapySettingKind
    let entry: TherapyScheduleEntry
    let isNew: Bool
    let isFirst: Bool
    let availableStarts: [Int]
    let glucoseUnit: HKUnit
    let onSave: (TherapyScheduleEntry) -> Void
    let onDelete: () -> Void

    @State private var start: Int = 0
    @State private var valueText: String = ""
    @FocusState private var valueFocused: Bool

    private var digits: Int { kind.fractionDigits(glucoseUnit: glucoseUnit) }

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter
    }

    private var parsedValue: Double? {
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        guard let number = formatter.number(from: trimmed) ?? Double(trimmed.replacingOccurrences(of: ",", with: ".")).map({ NSNumber(value: $0) }) else {
            return nil
        }
        let scale = pow(10, Double(digits))
        return (number.doubleValue * scale).rounded() / scale
    }

    private var range: ClosedRange<Double> {
        TherapySchedule.allowedRangeRounded(kind: kind, glucoseUnit: glucoseUnit)
    }

    private var isValid: Bool {
        guard let parsedValue else { return false }
        return range.contains(parsedValue)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Starts At")) {
                    if isFirst {
                        HStack {
                            Text("00:00")
                            Spacer()
                            Text("The first time is always midnight")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Time", selection: $start) {
                            ForEach(availableStarts, id: \.self) { start in
                                Text(TherapySchedule.timeString(start)).tag(start)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }

                Section(
                    header: Text(kind.title),
                    footer: Text("Loop allows \(formatter.string(from: range.lowerBound as NSNumber) ?? "")–\(formatter.string(from: range.upperBound as NSNumber) ?? "") \(kind.unitLabel(glucoseUnit: glucoseUnit)).")
                ) {
                    HStack {
                        TextField("Value", text: $valueText)
                            .keyboardType(digits == 0 ? .numberPad : .decimalPad)
                            .focused($valueFocused)
                        Text(kind.unitLabel(glucoseUnit: glucoseUnit))
                            .foregroundColor(.secondary)
                    }
                    if !valueText.isEmpty && !isValid {
                        Text("Outside what Loop allows")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if !isNew && !isFirst {
                    Section {
                        Button("Remove This Time", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Time" : TherapySchedule.timeString(entry.start))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let parsedValue else { return }
                        onSave(TherapyScheduleEntry(id: entry.id, start: isFirst ? 0 : start, value: parsedValue))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                start = entry.start
                valueText = formatter.string(from: entry.value as NSNumber) ?? ""
                valueFocused = true
            }
        }
    }
}
