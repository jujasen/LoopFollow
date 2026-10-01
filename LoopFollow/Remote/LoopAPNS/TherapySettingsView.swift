// LoopFollow
// TherapySettingsView.swift

import HealthKit
import SwiftUI

/// Edits Loop's therapy settings from this phone, grouped like Loop's own Therapy Settings screen.
/// Values start from the profile Loop last uploaded to Nightscout; the changed ones are reviewed and
/// sent back as one remote command, which Loop checks again before saving anything.
struct TherapySettingsView: View {
    @Environment(\.presentationMode) var presentationMode

    @State private var original = TherapySettingsDraft(glucoseUnit: .millimolesPerLiter)
    @State private var draft = TherapySettingsDraft(glucoseUnit: .millimolesPerLiter)
    @State private var loadedAt: Date?
    @State private var didLoad = false

    @State private var numberEdit: TherapyNumberEdit?
    @State private var presetEdit: PresetEdit?
    @State private var showReview = false
    @State private var sendAfterReview = false

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
    }

    struct PresetEdit: Identifiable {
        let preset: OverridePresetDraft
        let isNew: Bool
        var id: UUID { preset.id }
    }

    // MARK: - Derived state

    private var unit: HKUnit { draft.glucoseUnit }
    private var glucoseDigits: Int { draft.glucoseDigits }
    private var glucoseUnitLabel: String { draft.glucoseUnitLabel }

    private func isChanged(_ setting: TherapySetting) -> Bool {
        draft.isChanged(setting, from: original)
    }

    private var hasChanges: Bool { draft != original }

    private var issues: [TherapyIssue] { draft.issues(comparedTo: original) }

    private var blockingIssues: [TherapyIssue] { issues.filter { $0.severity == .blocking } }

    private var hasProfile: Bool {
        !original.carbRatios.isEmpty || !original.sensitivities.isEmpty || !original.basalRates.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            Form {
                if !hasProfile {
                    Section {
                        Text("No therapy settings have been read from Nightscout yet. They appear here once Loop's profile has loaded.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        Text(headerText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    dosingSection
                    glucoseSafetyLimitSection
                    correctionRangeSection
                    rangeSection(.preMealRange, range: draft.preMealRange, footer: "The target Loop uses while Pre-Meal is on, until carbs are entered.")
                    rangeSection(.workoutRange, range: draft.workoutRange, footer: "The target Loop uses while the Workout override is on.")
                    scheduleSection(.carbRatio)
                    scheduleSection(.basalRate)
                    deliveryLimitsSection
                    scheduleSection(.insulinSensitivity)
                    insulinModelSection
                    overridePresetsSection
                    experimentsSection

                    if !blockingIssues.isEmpty {
                        Section(header: Text("Can't Send Yet")) {
                            ForEach(blockingIssues) { issue in
                                Label("\(issue.setting.title): \(issue.message)", systemImage: "xmark.octagon.fill")
                                    .foregroundColor(.red)
                                    .font(.callout)
                            }
                        }
                    }

                    if isTOTPBlocked && showTOTPWarning {
                        Section {
                            Text("This OTP code has already been used for a command. Wait for the next code before sending.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    securitySection
                }
            }
            .safeAreaInset(edge: .bottom) {
                if hasProfile {
                    Button(action: review) {
                        if isLoading {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Sending...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Review Changes")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasChanges || !blockingIssues.isEmpty || isLoading || isTOTPBlocked)
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
                        Button("Revert") { draft = original }
                    }
                }
            }
            .sheet(item: $numberEdit) { edit in
                TherapyNumberEditor(edit: edit)
            }
            .sheet(item: $presetEdit) { edit in
                OverridePresetEditor(
                    preset: edit.preset,
                    isNew: edit.isNew,
                    otherNames: Set((draft.overridePresets ?? []).filter { $0.id != edit.preset.id }.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }),
                    glucoseUnit: unit,
                    onSave: savePreset,
                    onDelete: { deletePreset(edit.preset) }
                )
            }
            .sheet(isPresented: $showReview, onDismiss: {
                if sendAfterReview {
                    sendAfterReview = false
                    authenticateAndSend()
                }
            }) {
                TherapyReviewView(
                    changes: draft.changes(from: original),
                    warnings: issues.filter { $0.severity == .warning },
                    onSend: {
                        sendAfterReview = true
                        showReview = false
                    },
                    onCancel: { showReview = false }
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
                }
            }
        }
    }

    private var headerText: String {
        var text = "Tap a value to change it. Changes are reviewed before they are sent, and Loop checks them again: if one value is outside what Loop allows, nothing is changed."
        if let loadedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            text = "Read from Loop's Nightscout profile \(formatter.localizedString(for: loadedAt, relativeTo: Date())). " + text
        }
        return text
    }

    // MARK: - Sections

    private var dosingSection: some View {
        Section(header: Text("Dosing"), footer: issuesFooter([.closedLoop, .dosingStrategy])) {
            boolRow(.closedLoop, value: $draft.closedLoop)
            Picker(selection: $draft.dosingStrategy) {
                if draft.dosingStrategy == nil {
                    Text("Unknown").tag(String?.none)
                }
                ForEach(DosingStrategyOption.allCases) { option in
                    Text(option.title).tag(String?.some(option.rawValue))
                }
                if let current = draft.dosingStrategy, DosingStrategyOption(rawValue: current) == nil {
                    Text(current).tag(String?.some(current))
                }
            } label: {
                changedLabel(.dosingStrategy)
            }
        }
    }

    private var glucoseSafetyLimitSection: some View {
        Section(
            header: Text(TherapySetting.glucoseSafetyLimit.title),
            footer: issuesFooter([.glucoseSafetyLimit], note: "Loop doesn't dose below this glucose.")
        ) {
            valueRow(
                title: TherapySetting.glucoseSafetyLimit.title,
                value: draft.suspendThreshold.map { glucose($0) },
                isChanged: isChanged(.glucoseSafetyLimit)
            ) {
                editGlucoseValue(.glucoseSafetyLimit, value: draft.suspendThreshold) { draft.suspendThreshold = $0 }
            }
        }
    }

    private var correctionRangeSection: some View {
        let original = Dictionary(self.original.correctionRanges.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
        return Section(
            header: Text("\(TherapySetting.correctionRange.title) (\(glucoseUnitLabel))"),
            footer: issuesFooter([.correctionRange], note: "The range Loop aims for. Each range applies from its time until the next.")
        ) {
            if draft.correctionRanges.isEmpty {
                Text("Unknown").foregroundColor(.secondary)
            }
            ForEach(draft.correctionRanges) { entry in
                Button {
                    editCorrectionRange(entry, isNew: false)
                } label: {
                    scheduleRowLabel(
                        start: entry.start,
                        value: TherapySchedule.formatRange(entry.low, entry.high, digits: glucoseDigits) + " " + glucoseUnitLabel,
                        isChanged: original[entry.start] != entry
                    )
                }
                .deleteDisabled(entry.start == 0)
            }
            .onDelete { offsets in
                let current = draft.correctionRanges
                let removed = Set(offsets.filter { current[$0].start != 0 }.map { current[$0].id })
                draft.correctionRanges.removeAll { removed.contains($0.id) }
            }

            Button {
                if draft.correctionRanges.isEmpty {
                    editCorrectionRange(TherapyRangeEntry(start: 0, low: .nan, high: .nan), isNew: true)
                } else if let entry = TherapySchedule.newRangeEntry(after: draft.correctionRanges) {
                    editCorrectionRange(entry, isNew: true)
                }
            } label: {
                Label(draft.correctionRanges.isEmpty ? "Set Correction Range" : "Add Time", systemImage: "plus")
            }
            .disabled(draft.correctionRanges.count >= TherapySchedule.maximumEntryCount)
        }
    }

    private func rangeSection(_ setting: TherapySetting, range: ClosedRange<Double>?, footer: String) -> some View {
        Section(
            header: Text(setting.title),
            footer: issuesFooter([setting], note: footer)
        ) {
            valueRow(
                title: setting.title,
                value: range.map { TherapySchedule.formatRange($0.lowerBound, $0.upperBound, digits: glucoseDigits) + " " + glucoseUnitLabel },
                isChanged: isChanged(setting)
            ) {
                editGlucoseRange(setting, range: range) { newRange in
                    if setting == .preMealRange {
                        draft.preMealRange = newRange
                    } else {
                        draft.workoutRange = newRange
                    }
                }
            }
        }
    }

    private func scheduleSection(_ kind: TherapySettingKind) -> some View {
        let setting = Self.setting(for: kind)
        let unitLabel = kind.unitLabel(glucoseUnit: unit)
        let digits = kind.fractionDigits(glucoseUnit: unit)
        let entries = draft.entries(for: kind)
        let original = Dictionary(self.original.entries(for: kind).map { ($0.start, $0.value) }, uniquingKeysWith: { first, _ in first })

        return Section(
            header: Text("\(kind.title) (\(unitLabel))"),
            footer: issuesFooter([setting], note: "Each value applies from its time until the next. Tap a time to change it, swipe to remove it.")
        ) {
            if entries.isEmpty {
                Text("Unknown").foregroundColor(.secondary)
            }
            ForEach(entries) { entry in
                Button {
                    editScheduleEntry(entry, kind: kind, isNew: false)
                } label: {
                    scheduleRowLabel(
                        start: entry.start,
                        value: TherapySchedule.format(entry.value, digits: digits) + " " + unitLabel,
                        isChanged: original[entry.start] != entry.value
                    )
                }
                .deleteDisabled(entry.start == 0)
            }
            .onDelete { offsets in
                let current = draft.entries(for: kind)
                let removed = Set(offsets.filter { current[$0].start != 0 }.map { current[$0].id })
                draft.setEntries(current.filter { !removed.contains($0.id) }, for: kind)
            }

            Button {
                if entries.isEmpty {
                    editScheduleEntry(TherapyScheduleEntry(start: 0, value: .nan), kind: kind, isNew: true)
                } else if let entry = TherapySchedule.newEntry(after: entries, maximumCount: kind.maximumEntryCount) {
                    editScheduleEntry(entry, kind: kind, isNew: true)
                }
            } label: {
                Label("Add Time", systemImage: "plus")
            }
            .disabled(entries.count >= kind.maximumEntryCount)
        }
    }

    private var deliveryLimitsSection: some View {
        Section(
            header: Text("Delivery Limits"),
            footer: issuesFooter([.maximumBasalRate, .maximumBolus], note: "The most insulin Loop gives as a temp basal, and in one bolus.")
        ) {
            valueRow(
                title: TherapySetting.maximumBasalRate.title,
                value: draft.maximumBasalRate.map { TherapySchedule.format($0, digits: 3) + " U/h" },
                isChanged: isChanged(.maximumBasalRate)
            ) {
                editInsulinValue(.maximumBasalRate, value: draft.maximumBasalRate, unitLabel: "U/h") { draft.maximumBasalRate = $0 }
            }
            valueRow(
                title: TherapySetting.maximumBolus.title,
                value: draft.maximumBolus.map { TherapySchedule.format($0, digits: 3) + " U" },
                isChanged: isChanged(.maximumBolus)
            ) {
                editInsulinValue(.maximumBolus, value: draft.maximumBolus, unitLabel: "U") { draft.maximumBolus = $0 }
            }
        }
    }

    private var insulinModelSection: some View {
        Section(header: Text(TherapySetting.insulinModel.title), footer: issuesFooter([.insulinModel])) {
            Picker(selection: $draft.insulinModel) {
                if draft.insulinModel == nil {
                    Text("Unknown").tag(String?.none)
                }
                ForEach(InsulinModelOption.selectable) { option in
                    Text(option.title).tag(String?.some(option.rawValue))
                }
                if let current = draft.insulinModel, !InsulinModelOption.selectable.map(\.rawValue).contains(current) {
                    Text(InsulinModelOption.title(for: current)).tag(String?.some(current))
                }
            } label: {
                changedLabel(.insulinModel)
            }
        }
    }

    private var overridePresetsSection: some View {
        let originalByID = Dictionary((original.overridePresets ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Section(
            header: Text(TherapySetting.overridePresets.title),
            footer: issuesFooter([.overridePresets], note: draft.overridePresets == nil
                ? "Loop's override presets haven't been read from Nightscout, so they can't be changed here."
                : "Loop's preset list is replaced as a whole with this one.")
        ) {
            if let presets = draft.overridePresets {
                if presets.isEmpty {
                    Text("No presets").foregroundColor(.secondary)
                }
                ForEach(presets) { preset in
                    Button {
                        presetEdit = PresetEdit(preset: preset, isNew: false)
                    } label: {
                        HStack {
                            Text(preset.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundColor(.primary)
                                Text(preset.summary(glucoseUnit: unit))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if originalByID[preset.id] != preset {
                                changeDot
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let removed = Set(offsets.map { presets[$0].id })
                    draft.overridePresets?.removeAll { removed.contains($0.id) }
                }

                Button {
                    presetEdit = PresetEdit(preset: OverridePresetDraft(name: "", symbol: "", duration: 3600), isNew: true)
                } label: {
                    Label("Add Preset", systemImage: "plus")
                }
            } else {
                Text("Unknown").foregroundColor(.secondary)
            }
        }
    }

    private var experimentsSection: some View {
        Section(
            header: Text("Algorithm Experiments"),
            footer: issuesFooter([.glucoseBasedPartialApplication, .integralRetrospectiveCorrection],
                                 note: "Unknown means Nightscout doesn't show the current value; it stays as it is in Loop unless a value is picked.")
        ) {
            boolRow(.glucoseBasedPartialApplication, value: $draft.glucoseBasedPartialApplication)
            boolRow(.integralRetrospectiveCorrection, value: $draft.integralRetrospectiveCorrection)
        }
    }

    private var securitySection: some View {
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

    // MARK: - Rows

    private var changeDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundColor(.orange)
    }

    private func changedLabel(_ setting: TherapySetting) -> some View {
        HStack {
            Text(setting.title)
            if isChanged(setting) {
                changeDot
            }
        }
    }

    private func valueRow(title: String, value: String?, isChanged: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer()
                if isChanged {
                    changeDot
                }
                Text(value ?? "Unknown")
                    .foregroundColor(value == nil ? .secondary : .primary)
            }
        }
    }

    private func scheduleRowLabel(start: Int, value: String, isChanged: Bool) -> some View {
        HStack {
            Text(TherapySchedule.timeString(start))
                .font(.body.monospacedDigit())
                .foregroundColor(.primary)
            Spacer()
            if isChanged {
                changeDot
            }
            Text(value)
                .foregroundColor(.primary)
        }
    }

    /// A switch for a known value; a picker with "Unknown" while Nightscout doesn't show it, so the
    /// setting is only sent once On or Off has been picked.
    @ViewBuilder
    private func boolRow(_ setting: TherapySetting, value: Binding<Bool?>) -> some View {
        if value.wrappedValue == nil {
            Picker(selection: value) {
                Text("Unknown").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            } label: {
                changedLabel(setting)
            }
        } else {
            Toggle(isOn: Binding(get: { value.wrappedValue ?? false }, set: { value.wrappedValue = $0 })) {
                changedLabel(setting)
            }
        }
    }

    private func issuesFooter(_ settings: [TherapySetting], note: String? = nil) -> some View {
        let shown = issues.filter { settings.contains($0.setting) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { issue in
                Label(issue.message, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(issue.severity == .blocking ? .red : .orange)
            }
            if let note {
                Text(note)
            }
        }
    }

    private func glucose(_ value: Double) -> String {
        TherapySchedule.format(value, digits: glucoseDigits) + " " + glucoseUnitLabel
    }

    private static func setting(for kind: TherapySettingKind) -> TherapySetting {
        switch kind {
        case .carbRatio: return .carbRatio
        case .basalRate: return .basalRate
        case .insulinSensitivity: return .insulinSensitivity
        }
    }

    // MARK: - Editing

    /// Runs once: `onAppear` fires again when an edit sheet closes, and must not throw away edits.
    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let profile = ProfileManager.shared
        loadedAt = profile.loadedAt
        original = TherapySettingsDraft.fromProfile(profile)
        draft = original

        if !LoopAPNSService().validateSetup() {
            alertMessage = "Loop APNS setup is incomplete. Please configure all required fields in settings."
            alertType = .error
            showAlert = true
        }
    }

    /// Loop's bounds for a setting, given the draft's other settings as they are now.
    private func bounds(for setting: TherapySetting) -> TherapyBounds? {
        draft.bounds(for: setting)
    }

    private func editGlucoseValue(_ setting: TherapySetting, value: Double?, save: @escaping (Double) -> Void) {
        guard let limits = TherapyGuardrails.limits(for: setting, unit: unit), let bounds = bounds(for: setting) else { return }
        numberEdit = TherapyNumberEdit(
            title: setting.title, header: setting.title, unitLabel: glucoseUnitLabel, digits: glucoseDigits, increment: nil,
            limits: limits, bounds: bounds, time: .none, start: 0, values: [value], isRange: false, canDelete: false,
            onSave: { _, values in save(values[0]) }, onDelete: {}
        )
    }

    private func editInsulinValue(_ setting: TherapySetting, value: Double?, unitLabel: String, save: @escaping (Double) -> Void) {
        guard let limits = TherapyGuardrails.limits(for: setting, unit: unit), let bounds = bounds(for: setting) else { return }
        numberEdit = TherapyNumberEdit(
            title: setting.title, header: setting.title, unitLabel: unitLabel, digits: 2, increment: TherapyGuardrails.pumpIncrement,
            limits: limits, bounds: bounds, time: .none, start: 0, values: [value], isRange: false, canDelete: false,
            onSave: { _, values in save(values[0]) }, onDelete: {}
        )
    }

    private func editGlucoseRange(_ setting: TherapySetting, range: ClosedRange<Double>?, save: @escaping (ClosedRange<Double>) -> Void) {
        guard let limits = TherapyGuardrails.limits(for: setting, unit: unit), let bounds = bounds(for: setting) else { return }
        numberEdit = TherapyNumberEdit(
            title: setting.title, header: setting.title, unitLabel: glucoseUnitLabel, digits: glucoseDigits, increment: nil,
            limits: limits, bounds: bounds, time: .none, start: 0, values: [range?.lowerBound, range?.upperBound], isRange: true, canDelete: false,
            onSave: { _, values in save(values[0] ... values[1]) }, onDelete: {}
        )
    }

    private func editCorrectionRange(_ entry: TherapyRangeEntry, isNew: Bool) {
        guard let limits = TherapyGuardrails.limits(for: .correctionRange, unit: unit), let bounds = bounds(for: .correctionRange) else { return }
        let isFirst = entry.start == 0 && (!isNew || draft.correctionRanges.isEmpty)
        let available = TherapySchedule.availableStarts(in: draft.correctionRanges, keeping: isNew ? nil : entry.start)
        numberEdit = TherapyNumberEdit(
            title: isNew ? "Add Time" : TherapySchedule.timeString(entry.start), header: TherapySetting.correctionRange.title,
            unitLabel: glucoseUnitLabel, digits: glucoseDigits, increment: nil, limits: limits, bounds: bounds,
            time: isFirst ? .first : .choose(available), start: entry.start,
            values: [entry.low.isNaN ? nil : entry.low, entry.high.isNaN ? nil : entry.high], isRange: true,
            canDelete: !isNew && !isFirst,
            onSave: { start, values in
                var entries = draft.correctionRanges
                let updated = TherapyRangeEntry(id: entry.id, start: start, low: values[0], high: values[1])
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index] = updated
                } else {
                    entries.append(updated)
                }
                draft.correctionRanges = TherapySchedule.sorted(entries)
            },
            onDelete: {
                guard entry.start != 0 else { return }
                draft.correctionRanges.removeAll { $0.id == entry.id }
            }
        )
    }

    private func editScheduleEntry(_ entry: TherapyScheduleEntry, kind: TherapySettingKind, isNew: Bool) {
        let setting = Self.setting(for: kind)
        guard let limits = TherapyGuardrails.limits(for: setting, unit: unit), let bounds = bounds(for: setting) else { return }
        let entries = draft.entries(for: kind)
        let isFirst = entry.start == 0 && (!isNew || entries.isEmpty)
        let available = TherapySchedule.availableStarts(in: entries, keeping: isNew ? nil : entry.start)
        numberEdit = TherapyNumberEdit(
            title: isNew ? "Add Time" : TherapySchedule.timeString(entry.start), header: kind.title,
            unitLabel: kind.unitLabel(glucoseUnit: unit), digits: kind.fractionDigits(glucoseUnit: unit), increment: kind.increment,
            limits: limits, bounds: bounds, time: isFirst ? .first : .choose(available), start: entry.start,
            values: [entry.value.isNaN ? nil : entry.value], isRange: false, canDelete: !isNew && !isFirst,
            onSave: { start, values in
                var entries = draft.entries(for: kind)
                let updated = TherapyScheduleEntry(id: entry.id, start: start, value: values[0])
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index] = updated
                } else {
                    entries.append(updated)
                }
                draft.setEntries(TherapySchedule.sorted(entries), for: kind)
            },
            onDelete: {
                guard entry.start != 0 else { return }
                draft.setEntries(draft.entries(for: kind).filter { $0.id != entry.id }, for: kind)
            }
        )
    }

    private func savePreset(_ preset: OverridePresetDraft) {
        var presets = draft.overridePresets ?? []
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        draft.overridePresets = presets
    }

    private func deletePreset(_ preset: OverridePresetDraft) {
        draft.overridePresets?.removeAll { $0.id == preset.id }
    }

    // MARK: - Sending

    private func review() {
        if let issue = blockingIssues.first {
            alertMessage = "\(issue.setting.title): \(issue.message)"
            alertType = .error
            showAlert = true
            return
        }
        showReview = true
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
        guard blockingIssues.isEmpty else { return }
        guard let otpCode = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            alertMessage = "Invalid QR code URL. Please re-scan the QR code in settings."
            alertType = .error
            showAlert = true
            return
        }

        let therapySettings = draft.payload(from: original)
        guard !therapySettings.isEmpty else { return }

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

// MARK: - Review

/// Every change, listed before anything is sent. Changes that let Loop give more insulin, or stop it
/// dosing, are highlighted.
private struct TherapyReviewView: View {
    let changes: [TherapyChange]
    let warnings: [TherapyIssue]
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(changes) { change in
                    Section(header: Text(change.setting.title)) {
                        ForEach(change.lines, id: \.self) { line in
                            Text(line)
                                .font(.body.monospacedDigit())
                        }
                        if let warning = change.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundColor(.red)
                                .listRowBackground(Color.red.opacity(0.12))
                        }
                    }
                }

                if !warnings.isEmpty {
                    Section(header: Text("Outside Loop's Recommendations")) {
                        ForEach(warnings) { issue in
                            Label("\(issue.setting.title): \(issue.message)", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section(footer: Text("Loop starts dosing with the new values right away. If any value is outside what Loop allows, nothing is changed. Loop confirms with a notification.")) {
                    Button(role: .destructive, action: onSend) {
                        Text("Send to Loop")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Review Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - Number editor

/// What a number editor sheet edits: one value or a low–high range, with a start time for a schedule row.
struct TherapyNumberEdit: Identifiable {
    enum Time {
        case none
        case first
        case choose([Int])
    }

    let id = UUID()
    let title: String
    let header: String
    let unitLabel: String
    let digits: Int
    /// Values are rounded to this step (the pump's 0.05 U) when saved.
    let increment: Double?
    /// The editor won't save a value outside.
    let limits: ClosedRange<Double>
    /// Loop's bounds with the other settings as they are now; outside is shown, not prevented.
    let bounds: TherapyBounds
    let time: Time
    let start: Int
    /// One value, or `[low, high]`; nil while unknown.
    let values: [Double?]
    let isRange: Bool
    let canDelete: Bool
    let onSave: (Int, [Double]) -> Void
    let onDelete: () -> Void
}

private struct TherapyNumberEditor: View {
    @Environment(\.dismiss) private var dismiss

    let edit: TherapyNumberEdit

    @State private var start: Int = 0
    @State private var texts: [String] = []
    @FocusState private var focused: Int?

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = edit.digits
        return formatter
    }

    private func format(_ value: Double) -> String {
        TherapySchedule.format(value, digits: edit.digits)
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let number = formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        if let increment = edit.increment {
            return TherapySchedule.round((number / increment).rounded() * increment, digits: 3)
        }
        return TherapySchedule.round(number, digits: edit.digits)
    }

    private var parsed: [Double]? {
        let values = texts.compactMap(parse)
        return values.count == texts.count && !texts.isEmpty ? values : nil
    }

    private var problem: String? {
        guard let parsed else { return texts.contains(where: { !$0.isEmpty }) ? "Enter a number" : nil }
        if let outside = parsed.first(where: { !edit.limits.contains($0) }) {
            return "\(format(outside)) is outside what Loop allows (\(format(edit.limits.lowerBound))–\(format(edit.limits.upperBound)) \(edit.unitLabel))."
        }
        if edit.isRange, parsed[0] > parsed[1] {
            return "The low value must not be above the high value."
        }
        return nil
    }

    private var notes: [String] {
        guard let parsed, problem == nil else { return [] }
        var notes = [String]()
        if let outside = parsed.first(where: { !edit.bounds.absolute.contains($0) }) {
            notes.append("With Loop's other settings as they are, \(format(outside)) is outside the allowed \(format(edit.bounds.absolute.lowerBound))–\(format(edit.bounds.absolute.upperBound)) \(edit.unitLabel). Change the other setting too before sending.")
        } else if parsed.contains(where: { !edit.bounds.recommended.contains($0) }) {
            notes.append("Outside Loop's recommended \(format(edit.bounds.recommended.lowerBound))–\(format(edit.bounds.recommended.upperBound)) \(edit.unitLabel).")
        }
        if let increment = edit.increment {
            let typed = texts.compactMap { text -> Double? in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
            }
            if zip(typed, parsed).contains(where: { abs($0 - $1) > 1e-9 }) {
                notes.append("The pump delivers in steps of \(TherapySchedule.format(increment, digits: 2)) \(edit.unitLabel); this is saved as \(parsed.map(format).joined(separator: "–")) \(edit.unitLabel).")
            }
        }
        return notes
    }

    var body: some View {
        NavigationView {
            Form {
                switch edit.time {
                case .none:
                    EmptyView()
                case .first:
                    Section(header: Text("Starts At")) {
                        HStack {
                            Text("00:00")
                            Spacer()
                            Text("The first time is always midnight")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                case let .choose(starts):
                    Section(header: Text("Starts At")) {
                        Picker("Time", selection: $start) {
                            ForEach(starts, id: \.self) { start in
                                Text(TherapySchedule.timeString(start)).tag(start)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }

                Section(
                    header: Text(edit.header),
                    footer: Text("Loop allows \(format(edit.limits.lowerBound))–\(format(edit.limits.upperBound)) \(edit.unitLabel).")
                ) {
                    ForEach(texts.indices, id: \.self) { index in
                        HStack {
                            if edit.isRange {
                                Text(index == 0 ? "Low" : "High")
                                    .frame(width: 48, alignment: .leading)
                            }
                            TextField("Value", text: $texts[index])
                                .keyboardType(edit.digits == 0 ? .numberPad : .decimalPad)
                                .focused($focused, equals: index)
                            Text(edit.unitLabel)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if edit.canDelete {
                    Section {
                        Button("Remove This Time", role: .destructive) {
                            edit.onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let parsed, problem == nil else { return }
                        let start: Int
                        if case .choose = edit.time { start = self.start } else { start = edit.start }
                        edit.onSave(start, parsed)
                        dismiss()
                    }
                    .disabled(parsed == nil || problem != nil)
                }
            }
            .onAppear {
                start = edit.start
                texts = edit.values.map { $0.map(format) ?? "" }
                focused = 0
            }
        }
    }
}

// MARK: - Override preset editor

/// Edits one override preset the way Loop's preset editor does: a symbol and name, overall insulin
/// needs from 10 % to 200 %, an optional target range, and a duration or indefinite.
private struct OverridePresetEditor: View {
    @Environment(\.dismiss) private var dismiss

    let preset: OverridePresetDraft
    let isNew: Bool
    let otherNames: Set<String>
    let glucoseUnit: HKUnit
    let onSave: (OverridePresetDraft) -> Void
    let onDelete: () -> Void

    @State private var name = ""
    @State private var symbol = ""
    @State private var percent = 100
    @State private var hasTarget = false
    @State private var lowText = ""
    @State private var highText = ""
    @State private var indefinite = false
    @State private var hours = 1
    @State private var minutes = 0

    private var digits: Int { TherapyGuardrails.glucoseDigits(glucoseUnit) }

    private var percentOptions: [Int] {
        var options = Array(stride(from: 10, through: 200, by: 10))
        if !options.contains(percent) {
            options.append(percent)
            options.sort()
        }
        return options
    }

    private var minuteOptions: [Int] {
        var options = Array(stride(from: 0, to: 60, by: 5))
        if !options.contains(minutes) {
            options.append(minutes)
            options.sort()
        }
        return options
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return TherapySchedule.round(value, digits: digits)
    }

    private var target: ClosedRange<Double>? {
        guard hasTarget, let low = parse(lowText), let high = parse(highText), low > 0, low <= high else { return nil }
        return low ... high
    }

    private var duration: Int { indefinite ? 0 : hours * 3600 + minutes * 60 }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var problem: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        if otherNames.contains(trimmedName) { return "Another preset already has this name." }
        if symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a symbol, such as an emoji." }
        if hasTarget && target == nil { return "Enter a target range with the low value not above the high value." }
        if let target {
            let limits = TherapyGuardrails.overrideTargetLimits(unit: glucoseUnit)
            if !limits.contains(target.lowerBound) || !limits.contains(target.upperBound) {
                let allowed = TherapySchedule.formatRange(limits.lowerBound, limits.upperBound, digits: digits)
                return "The target must be within \(allowed) \(glucoseUnit.localizedShortUnitString)."
            }
        }
        if !indefinite && duration > TherapyGuardrails.maximumOverrideDuration { return "A preset lasts at most 24 hours." }
        if !hasTarget && percent == 100 { return "Set a target or overall insulin needs other than 100%." }
        if !indefinite && duration == 0 { return "Choose a duration, or make the preset indefinite." }
        return nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Symbol")
                        Spacer()
                        TextField("🏃", text: $symbol)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                    }
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Running", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section(header: Text("Overall Insulin Needs")) {
                    Picker("Insulin Needs", selection: $percent) {
                        ForEach(percentOptions, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                }

                Section(
                    header: Text("Target Range"),
                    footer: Text(hasTarget ? "Loop aims for this range while the preset is on." : "Loop keeps using the Correction Range.")
                ) {
                    Toggle("Custom Target", isOn: $hasTarget)
                    if hasTarget {
                        HStack {
                            Text("Low").frame(width: 48, alignment: .leading)
                            TextField("Low", text: $lowText)
                                .keyboardType(digits == 0 ? .numberPad : .decimalPad)
                            Text(glucoseUnit.localizedShortUnitString).foregroundColor(.secondary)
                        }
                        HStack {
                            Text("High").frame(width: 48, alignment: .leading)
                            TextField("High", text: $highText)
                                .keyboardType(digits == 0 ? .numberPad : .decimalPad)
                            Text(glucoseUnit.localizedShortUnitString).foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Duration")) {
                    Toggle("Enable Indefinitely", isOn: $indefinite)
                    if !indefinite {
                        Picker("Hours", selection: $hours) {
                            ForEach(0 ..< 25, id: \.self) { Text("\($0) h").tag($0) }
                        }
                        Picker("Minutes", selection: $minutes) {
                            ForEach(minuteOptions, id: \.self) { Text("\($0) min").tag($0) }
                        }
                    }
                }

                if let problem {
                    Section {
                        Text(problem)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete Preset", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Preset" : preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard problem == nil else { return }
                        onSave(OverridePresetDraft(
                            id: preset.id,
                            name: trimmedName,
                            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines),
                            duration: duration,
                            insulinNeedsScaleFactor: Double(percent) / 100,
                            targetRange: hasTarget ? target : nil
                        ))
                        dismiss()
                    }
                    .disabled(problem != nil)
                }
            }
            .onAppear {
                name = preset.name
                symbol = preset.symbol
                percent = preset.insulinNeedsPercent
                if let range = preset.targetRange {
                    hasTarget = true
                    lowText = TherapySchedule.format(range.lowerBound, digits: digits)
                    highText = TherapySchedule.format(range.upperBound, digits: digits)
                }
                indefinite = preset.duration == 0 && !isNew
                hours = preset.duration / 3600
                minutes = (preset.duration % 3600) / 60
            }
        }
    }
}
