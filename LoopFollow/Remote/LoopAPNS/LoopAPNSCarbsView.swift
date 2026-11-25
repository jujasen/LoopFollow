// LoopFollow
// LoopAPNSCarbsView.swift

import HealthKit
import SwiftUI

struct LoopAPNSCarbsView: View {
    private typealias AbsorptionPreset = (hours: Int, minutes: Int)

    /// «Add meal», then (when Loop takes a meal with bolus) «Meal bolus».
    private enum Step {
        case meal
        case bolus
    }

    @Environment(\.presentationMode) var presentationMode
    @ObservedObject private var favoriteFoods = Storage.shared.favoriteFoods
    @ObservedObject private var loopRemoteCommands = Storage.shared.loopRemoteCommands
    @ObservedObject private var inbox = RemoteCommandInbox.shared
    @State private var step: Step = .meal
    @State private var carbsAmount = HKQuantity(unit: .gram(), doubleValue: 0.0)
    @State private var absorptionHours = 3
    @State private var absorptionMinutes = 0
    /// The emoji the graph shows («🍕»): from a favorite, the AI estimate or a tapped speed.
    @State private var foodEmoji = ""
    @State private var foodName = ""
    /// nil: now, whenever the meal is sent.
    @State private var consumedDate: Date?
    @State private var pickedDate = Date()
    @State private var showDatePickerSheet = false
    @State private var showAbsorptionPickerSheet = false
    @State private var isLoading = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var alertType: AlertType = .success
    @State private var showTOTPWarning = false
    @State private var selectedFavoriteFoodID: String?
    /// The favorites eaten most lately (`FavoriteFoodUsage`); the rest are under «All».
    @State private var usageLog = FavoriteFoodUsage.storedLog
    @State private var selectedPortionID: String?
    @State private var showFavoriteFoodPicker = false
    @State private var showAddFavoriteFood = false
    @StateObject private var mealEstimate = MealEstimateModel()
    /// Favorites there were when the editor was opened, to find (and select) the one it saved.
    @State private var favoriteIDsBeforeSave: Set<String>?
    /// The meal with bolus just sent, shown step by step.
    @State private var sentCommand: SentMealCommand?
    private let timeAdjustmentStepMinutes = 15
    private let maxPastHours = 12
    private let maxFutureHours = 1
    private let minAllowedAbsorptionTime = 0.5
    private let maxAllowedAbsorptionTime = 8.0

    @FocusState private var carbsFieldIsFocused: Bool

    private struct SentMealCommand: Identifiable {
        let id: String
    }

    private var isTOTPBlocked: Bool {
        TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
    }

    /// Loop takes the meal and its bolus as one command (`MealBolusCommand`); otherwise the carbs go
    /// alone, as before, and the bolus is sent from the bolus screen.
    private var offersMealBolus: Bool {
        MealBolusCommand.isOffered(remoteCommands: loopRemoteCommands.value, inboxAvailable: inbox.isAvailable)
    }

    private var carbsValue: Double {
        carbsAmount.doubleValue(for: .gram())
    }

    private var absorptionTimeValue: Double {
        Double(absorptionHours) + (Double(absorptionMinutes) / 60.0)
    }

    private var absorptionConfirmationText: String {
        Localizer.formatToLocalizedString(absorptionTimeValue, maxFractionDigits: 1, minFractionDigits: 1)
    }

    private var minimumAbsorptionPreset: AbsorptionPreset {
        let minimumAbsorptionMinutes = Int(minAllowedAbsorptionTime * 60)
        return (minimumAbsorptionMinutes / 60, minimumAbsorptionMinutes % 60)
    }

    private var maximumAbsorptionHours: Int {
        Int(maxAllowedAbsorptionTime)
    }

    private var absorptionValidationMessage: String {
        String(
            format: String(localized: "Please enter a valid absorption time between %.1f and %.1f hours"),
            minAllowedAbsorptionTime,
            maxAllowedAbsorptionTime
        )
    }

    private var absorptionMinuteOptions: [Int] {
        if absorptionHours == minimumAbsorptionPreset.hours {
            return [minimumAbsorptionPreset.minutes]
        }

        if absorptionHours == maximumAbsorptionHours {
            return [0]
        }

        return [0, 30]
    }

    private var oldestAcceptedDate: Date {
        Date().addingTimeInterval(-TimeInterval(maxPastHours) * 60 * 60)
    }

    private var latestAcceptedDate: Date {
        Date().addingTimeInterval(TimeInterval(maxFutureHours) * 60 * 60)
    }

    /// The speed segment for the absorption time, nil for any other time.
    private var absorptionPreset: MealAbsorption? {
        MealAbsorption(rawValue: absorptionHours * 60 + absorptionMinutes)
    }

    private var foodLabel: CarbFoodLabel {
        CarbFoodLabel(emoji: foodEmoji, name: foodName)
    }

    private var draft: MealDraft {
        MealDraft(carbs: carbsValue, absorptionHours: absorptionTimeValue, label: foodLabel, startDate: consumedDate ?? Date())
    }

    enum AlertType {
        case success
        case error
        case confirmation
    }

    var body: some View {
        NavigationView {
            Group {
                switch step {
                case .meal:
                    mealForm
                case .bolus:
                    MealBolusScreen(
                        draft: draft,
                        onSaveWithoutBolus: saveWithoutBolus,
                        isSavingCarbs: isLoading,
                        onSent: { command in sentCommand = SentMealCommand(id: command.commandId) }
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: step == .bolus)
            .navigationTitle(step == .meal ? String(localized: "Add meal", table: "MealBolus") : String(localized: "Meal bolus", table: "MealBolus"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step == .bolus {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            step = .meal
                        } label: {
                            Label(String(localized: "Meal", table: "MealBolus", comment: "Back button from the meal bolus to the meal"), systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", table: "MealBolus")) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        favoritesMenu
                    }
                }
            }
        }
        // Pushed from the remote screen, its bar would sit above this one with a second back button.
        .toolbar(.hidden, for: .navigationBar)
        .modifier(TOTPPeriodWatcher())
        .sheet(isPresented: $showDatePickerSheet) {
            NavigationStack {
                VStack {
                    DatePicker(
                        "Time",
                        selection: Binding(
                            get: { pickedDate },
                            set: { pickedDate = clampedConsumedDate($0) }
                        ),
                        in: oldestAcceptedDate ... latestAcceptedDate,
                        displayedComponents: [.hourAndMinute, .date]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding()

                    Spacer()
                }
                .navigationTitle("Consumption Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            setConsumedDate(clampedConsumedDate(pickedDate))
                            showDatePickerSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbsorptionPickerSheet) {
            NavigationStack {
                VStack {
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $absorptionHours) {
                            ForEach(0 ... maximumAbsorptionHours, id: \.self) { hour in
                                Text("\(hour) hr")
                                    .tag(hour)
                            }
                        }

                        Picker("Minutes", selection: $absorptionMinutes) {
                            ForEach(absorptionMinuteOptions, id: \.self) { minute in
                                Text("\(minute) min")
                                    .tag(minute)
                            }
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 180)
                    .padding(.horizontal)

                    Spacer()
                }
                .navigationTitle("Absorption Time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            normalizeAbsorptionTime()
                            showAbsorptionPickerSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .onAppear {
                normalizeAbsorptionTime()
            }
            .onChange(of: absorptionHours) { _ in
                normalizeAbsorptionTime()
            }
        }
        .sheet(isPresented: $showFavoriteFoodPicker) {
            FavoriteFoodPickerView(selectedFood: selectedFavoriteFood) { food, portion in
                if let food {
                    applyFavorite(food, portion: portion)
                } else {
                    clearFavoriteSelection()
                }
            }
        }
        .sheet(isPresented: $showAddFavoriteFood, onDismiss: selectSavedFavorite) {
            NavigationStack {
                AddEditFavoriteFoodView(
                    name: foodName,
                    carbs: carbsValue,
                    foodType: foodEmoji,
                    absorptionTime: absorptionTimeValue * 3600
                )
            }
        }
        .sheet(item: $sentCommand) { sent in
            MealSentSheet(commandId: sent.id) {
                sentCommand = nil
                presentationMode.wrappedValue.dismiss()
            }
            .interactiveDismissDisabled(false)
        }
        .onChange(of: carbsAmount) { _, newValue in
            // Typed by hand before asking the AI: known carbs, kept as they are by the estimate.
            if carbsFieldIsFocused {
                let grams = newValue.doubleValue(for: .gram())
                mealEstimate.knownCarbs = grams > 0 ? grams : nil
            }
            // A hand-edited amount is no longer the favorite that was picked.
            if let portion = selectedFavoriteFood?.portion(withID: selectedPortionID),
               abs(portion.carbs - newValue.doubleValue(for: .gram())) > 0.01
            {
                selectedFavoriteFoodID = nil
                selectedPortionID = nil
            }
        }
        .onReceive(mealEstimate.$estimate.compactMap { $0 }) { estimate in
            applyEstimate(estimate)
        }
        .onAppear {
            if !LoopAPNSService().validateSetup() {
                alertMessage = String(localized: "Loop APNS setup is incomplete. Please configure all required fields in settings.")
                alertType = .error
                showAlert = true
            }

            // Add delay before showing TOTP warning to prevent flash after successful send
            if isTOTPBlocked {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showTOTPWarning = true
                }
            } else {
                showTOTPWarning = false
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
                let timeFormatter = DateFormatter()
                timeFormatter.timeStyle = .short
                timeFormatter.dateStyle = .short
                return Alert(
                    title: Text("Confirm Carbs"),
                    message: Text("Send \(Int(carbsAmount.doubleValue(for: .gram())))g of carbs with \(absorptionConfirmationText)h absorption time at \(timeFormatter.string(from: consumedDate ?? Date()))?"),
                    primaryButton: .default(Text("Send")) {
                        sendCarbsConfirmed()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Step 1: the meal

    private var mealForm: some View {
        Form {
            favoriteFoodsSection

            // The AI estimate fills in the fields under it.
            MealEstimateSection(
                model: mealEstimate,
                onSaveFavorite: openFavoriteEditor,
                isSavedAsFavorite: selectedFavoriteFood != nil
            )

            Section {
                BigAmountRow(
                    label: String(localized: "Carbohydrates", table: "MealBolus"),
                    quantity: $carbsAmount,
                    unit: .gram(),
                    unitText: String(localized: "g", table: "MealBolus", comment: "Grams after the carb field"),
                    color: .systemGreen,
                    maxLength: 4,
                    minValue: HKQuantity(unit: .gram(), doubleValue: 1.0),
                    maxValue: Storage.shared.maxCarbs.value,
                    isFocused: $carbsFieldIsFocused,
                    onValidationError: { message in
                        alertMessage = message
                        alertType = .error
                        showAlert = true
                    }
                )

                timeRow

                HStack(spacing: 8) {
                    Text("Food", tableName: "MealBolus")
                    Spacer()
                    if !foodEmoji.isEmpty {
                        Text(foodEmoji)
                    }
                    TextField(String(localized: "Optional", table: "MealBolus", comment: "Placeholder of the food name field"), text: $foodName)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(.secondary)
                        .submitLabel(.done)
                        // Hugs the name, so the emoji sits right in front of it.
                        .fixedSize(horizontal: true, vertical: false)
                }

                absorptionRow
            } footer: {
                Text(offersMealBolus
                    ? String(localized: "The next screen shows what Loop will give as a bolus for this meal. Nothing is sent until you tap «Save and deliver».", table: "MealBolus")
                    : String(localized: "This Loop can't take a meal and its bolus as one command yet, so the carbs are sent on their own. Send the bolus afterwards from Bolus.", table: "MealBolus"))
            }

            if isTOTPBlocked && showTOTPWarning && !offersMealBolus {
                TOTPBlockedSection()
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: continueOrSend) {
                if isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Sending...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(offersMealBolus ? String(localized: "Continue", table: "MealBolus") : String(localized: "Save carbs", table: "MealBolus"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(carbsValue <= 0 || isLoading || (!offersMealBolus && isTOTPBlocked))
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Text("Time")
            Spacer()
            Button {
                adjustConsumedDate(byMinutes: -timeAdjustmentStepMinutes)
            } label: {
                Text("−15").font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "15 minutes earlier", table: "MealBolus"))

            Button {
                pickedDate = consumedDate ?? Date()
                showDatePickerSheet = true
            } label: {
                Group {
                    if let consumedDate {
                        Text(consumedDate, format: Date.FormatStyle().hour().minute())
                    } else {
                        Text("Now", tableName: "MealBolus", comment: "The meal's time when it is now")
                    }
                }
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundColor(.primary)
                .frame(minWidth: 52)
            }
            .buttonStyle(.plain)

            Button {
                adjustConsumedDate(byMinutes: timeAdjustmentStepMinutes)
            } label: {
                Text("+15").font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "15 minutes later", table: "MealBolus"))
        }
    }

    private var absorptionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How fast is it absorbed?", tableName: "MealBolus")
            Picker(String(localized: "Absorption", table: "MealBolus"), selection: Binding(
                get: { absorptionPreset },
                set: { preset in
                    guard let preset else { return }
                    setAbsorptionTime(hours: preset.minutes / 60, minutes: preset.minutes % 60)
                    // As the emoji buttons did: the speed tapped is what the graph shows, unless the
                    // meal has its own emoji.
                    if foodEmoji.isEmpty || MealAbsorption.allCases.contains(where: { $0.emoji == foodEmoji }) {
                        foodEmoji = preset.emoji
                    }
                }
            )) {
                ForEach(MealAbsorption.allCases) { preset in
                    Text(preset.title + " " + MealAbsorption.shortText(hours: Double(preset.minutes) / 60))
                        .tag(Optional(preset))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                if let absorptionPreset {
                    Text(absorptionPreset.examples)
                        .foregroundColor(.secondary)
                } else {
                    Text(String(format: String(localized: "Own time: %@", table: "MealBolus", comment: "1: absorption time"), MealAbsorption.shortText(hours: absorptionTimeValue)))
                        .foregroundColor(.orange)
                }
                Spacer()
                Button(String(localized: "Other time…", table: "MealBolus")) {
                    showAbsorptionPickerSheet = true
                }
                .buttonStyle(.borderless)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sending

    /// «Continue» to the meal bolus, or (for a Loop without it) the carbs alone as before.
    private func continueOrSend() {
        guard validateMeal() else { return }
        carbsFieldIsFocused = false
        if offersMealBolus {
            step = .bolus
        } else {
            alertType = .confirmation
            showAlert = true
        }
    }

    /// The same checks as before sending carbs.
    private func validateMeal() -> Bool {
        guard carbsValue > 0 else {
            showError(String(localized: "Please enter a valid carb amount"))
            return false
        }
        let maxCarbs = Storage.shared.maxCarbs.value.doubleValue(for: .gram())
        if carbsValue > maxCarbs {
            showError(String(localized: "Carbs amount (\(Int(carbsValue))g) exceeds the maximum allowed (\(Int(maxCarbs))g). Please reduce the amount."))
            return false
        }
        let date = consumedDate ?? Date()
        let now = Date()
        if date < now.addingTimeInterval(-60 * 60 * Double(maxPastHours)) {
            showError(String(localized: "Time must be within the prior \(maxPastHours) hours"))
            return false
        }
        if date > now.addingTimeInterval(60 * 60 * Double(maxFutureHours)) {
            showError(String(localized: "Time must be within the next \(maxFutureHours) hour"))
            return false
        }
        guard absorptionTimeValue >= minAllowedAbsorptionTime, absorptionTimeValue <= maxAllowedAbsorptionTime else {
            showError(absorptionValidationMessage)
            return false
        }
        return true
    }

    private func showError(_ message: String) {
        alertMessage = message
        alertType = .error
        showAlert = true
    }

    /// «Save without bolus» on the meal bolus screen: the plain carb command.
    private func saveWithoutBolus() {
        guard validateMeal() else { return }
        if isTOTPBlocked && !inbox.isAvailable {
            showError(String(localized: "This TOTP code has already been used for a command. Please wait for the next code to be generated before sending another command."))
            return
        }
        sendCarbsConfirmed()
    }

    private func sendCarbsConfirmed() {
        isLoading = true

        // Extract OTP from QR code URL
        guard let otpCode = TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value) else {
            alertMessage = String(localized: "Invalid QR code URL. Please re-scan the QR code in settings.")
            alertType = .error
            isLoading = false
            showAlert = true
            return
        }

        let selectedAbsorptionTime = absorptionTimeValue
        guard selectedAbsorptionTime >= minAllowedAbsorptionTime, selectedAbsorptionTime <= maxAllowedAbsorptionTime else {
            alertMessage = absorptionValidationMessage
            alertType = .error
            isLoading = false
            showAlert = true
            return
        }

        // Create the APNS payload for carbs with custom time
        // We "randomize" the milliseconds to avoid issue with NS which
        // doesn't allow entries at the same second.
        let adjustedConsumedDate = (consumedDate ?? Date()).dateUsingCurrentSeconds()
        let payload = LoopAPNSPayload(
            type: .carbs,
            carbsAmount: carbsValue,
            absorptionTime: selectedAbsorptionTime,
            foodType: foodLabel.foodType,
            consumedDate: adjustedConsumedDate,
            otp: otpCode
        )

        let apnsService = LoopAPNSService()
        apnsService.sendCarbsViaAPNS(payload: payload) { success, errorMessage in
            DispatchQueue.main.async {
                self.isLoading = false
                if success {
                    let sentCarbs = carbsAmount.doubleValue(for: .gram())
                    if sentCarbs > 0 {
                        QuickPickMealsManager.shared.recordMeal(carbs: sentCarbs)
                    }
                    // Mark TOTP code as used
                    TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                    let timeFormatter = DateFormatter()
                    timeFormatter.timeStyle = .short
                    self.alertMessage = String(localized: "Carbs for \(timeFormatter.string(from: adjustedConsumedDate)) sent to Loop. LoopFollow warns you if Loop rejects them.")
                    self.alertType = .success
                    LogManager.shared.log(
                        category: .apns,
                        message: "Carbs sent - Amount: \(carbsAmount.doubleValue(for: .gram()))g, Absorption: \(absorptionConfirmationText)h, Time: \(adjustedConsumedDate)"
                    )
                } else {
                    self.alertMessage = errorMessage ?? String(localized: "Failed to send carbs. Check your Loop APNS configuration.")
                    self.alertType = .error
                    LogManager.shared.log(
                        category: .apns,
                        message: "Failed to send carbs: \(errorMessage ?? "unknown error")"
                    )
                }
                self.showAlert = true
            }
        }
    }

    private func openFavoriteEditor() {
        favoriteIDsBeforeSave = Set(favoriteFoods.value.map(\.id))
        showAddFavoriteFood = true
    }

    /// Selects the favorite just saved for what is on screen, so the screen shows it is saved.
    private func selectSavedFavorite() {
        defer { favoriteIDsBeforeSave = nil }
        guard let before = favoriteIDsBeforeSave,
              let saved = favoriteFoods.value.first(where: { !before.contains($0.id) }),
              let portion = saved.portions.first(where: { abs($0.carbs - carbsAmount.doubleValue(for: .gram())) < 0.01 })
        else { return }
        selectedFavoriteFoodID = saved.id
        selectedPortionID = portion.id
    }

    /// Fills in the fields from an AI estimate. Nothing is sent; the caregiver reviews and
    /// confirms as with a typed entry.
    private func applyEstimate(_ estimate: MealCarbEstimate) {
        carbsFieldIsFocused = false
        selectedFavoriteFoodID = nil
        selectedPortionID = nil
        carbsAmount = HKQuantity(unit: .gram(), doubleValue: estimate.roundedCarbs)
        foodEmoji = estimate.foodTypeEmoji
        foodName = estimate.name
        let components = FavoriteFoodAbsorption.components(estimate.absorptionTime)
        setAbsorptionTime(hours: components.hours, minutes: components.minutes)
    }

    private func setAbsorptionTime(hours: Int, minutes: Int) {
        absorptionHours = min(max(hours, 0), maximumAbsorptionHours)
        absorptionMinutes = minutes
        normalizeAbsorptionTime()
    }

    private func normalizeAbsorptionTime() {
        if absorptionTimeValue < minAllowedAbsorptionTime {
            absorptionHours = minimumAbsorptionPreset.hours
            absorptionMinutes = minimumAbsorptionPreset.minutes
            return
        }

        if absorptionTimeValue >= maxAllowedAbsorptionTime {
            absorptionHours = maximumAbsorptionHours
            absorptionMinutes = 0
            return
        }

        if !absorptionMinuteOptions.contains(absorptionMinutes) {
            absorptionMinutes = absorptionMinuteOptions.first ?? 0
        }
    }

    private func adjustConsumedDate(byMinutes minutes: Int) {
        let base = consumedDate ?? Date()
        let adjustedDate = Calendar.current.date(byAdding: .minute, value: minutes, to: base) ?? base
        setConsumedDate(clampedConsumedDate(adjustedDate))
    }

    /// Back within a minute of now is «now» again.
    private func setConsumedDate(_ date: Date) {
        consumedDate = abs(date.timeIntervalSinceNow) < 60 ? nil : date
    }

    private func clampedConsumedDate(_ date: Date) -> Date {
        min(max(date, oldestAcceptedDate), latestAcceptedDate)
    }
}

// MARK: - Favorite foods

extension LoopAPNSCarbsView {
    /// The most eaten favorites, with the one picked from the full list first when it isn't among them.
    private var quickPickFavorites: [StoredFavoriteFood] {
        let top = FavoriteFoodUsage.mostUsed(favoriteFoods.value, log: usageLog, now: Date())
        if let selected = selectedFavoriteFood, !top.contains(where: { $0.id == selected.id }) {
            return [selected] + top
        }
        return top
    }

    /// The favorite currently applied to the entry, if it still exists.
    private var selectedFavoriteFood: StoredFavoriteFood? {
        guard let selectedFavoriteFoodID else { return nil }
        return favoriteFoods.value.first(where: { $0.id == selectedFavoriteFoodID })
    }

    /// Saved meals: one tap fills in carbs, food type and absorption time. Nothing is sent
    /// until the entry is reviewed and confirmed, exactly as with a typed entry.
    @ViewBuilder
    private var favoriteFoodsSection: some View {
        if favoriteFoods.value.isEmpty {
            Section {
                NavigationLink {
                    FavoriteFoodsView()
                } label: {
                    Label(String(localized: "Add favorite foods"), systemImage: "star")
                }
            }
        } else {
            Section(header: Text("Favorite Foods")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPickFavorites) { food in
                            favoriteFoodControl(for: food)
                        }
                        Button {
                            showFavoriteFoodPicker = true
                        } label: {
                            Text("All", tableName: "MealBolus", comment: "Chip that opens all favorite foods")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .task {
                await FavoriteFoodUsage.seedIfNeeded()
                usageLog = FavoriteFoodUsage.storedLog
            }
        }
    }

    /// Saving what is on screen as a favorite, and editing them, in the top bar.
    private var favoritesMenu: some View {
        Menu {
            Button {
                openFavoriteEditor()
            } label: {
                Label("Save as favorite food", systemImage: "star")
            }
            .disabled(carbsAmount.doubleValue(for: .gram()) <= 0)

            Button {
                showFavoriteFoodPicker = true
            } label: {
                Label("Browse all favorites", systemImage: "list.bullet")
            }
            .disabled(favoriteFoods.value.isEmpty)
        } label: {
            Image(systemName: "star.circle")
        }
        .accessibilityLabel(Text("Favorite Foods"))
    }

    @ViewBuilder
    private func favoriteFoodControl(for food: StoredFavoriteFood) -> some View {
        let isSelected = selectedFavoriteFoodID == food.id
        let selectedPortion = isSelected ? food.portion(withID: selectedPortionID) : nil

        if food.hasMultiplePortions {
            Menu {
                ForEach(food.portions) { portion in
                    Button(portion.summary) {
                        toggleFavoriteFood(food, portion: portion)
                    }
                }

                if isSelected {
                    Button(role: .destructive) {
                        clearFavoriteSelection()
                    } label: {
                        Label("Clear selection", systemImage: "xmark.circle")
                    }
                }
            } label: {
                FavoriteFoodChip(food: food, selectedPortion: selectedPortion, isSelected: isSelected)
            }
        } else {
            Button {
                toggleFavoriteFood(food)
            } label: {
                FavoriteFoodChip(food: food, selectedPortion: selectedPortion, isSelected: isSelected)
            }
            .buttonStyle(.plain)
        }
    }

    /// Tapping the food and amount that is already applied clears it, so one control both
    /// applies and undoes. Picking a different amount of the same food just switches amount.
    private func toggleFavoriteFood(_ food: StoredFavoriteFood, portion: FavoriteFoodPortion? = nil) {
        let portion = portion ?? food.defaultPortion
        if selectedFavoriteFoodID == food.id, selectedPortionID == portion.id {
            clearFavoriteSelection()
        } else {
            applyFavorite(food, portion: portion)
        }
    }

    private func applyFavorite(_ food: StoredFavoriteFood, portion: FavoriteFoodPortion?) {
        let portion = portion ?? food.defaultPortion
        carbsFieldIsFocused = false
        carbsAmount = HKQuantity(unit: .gram(), doubleValue: portion.carbs)
        foodEmoji = food.foodType
        foodName = food.name
        let components = FavoriteFoodAbsorption.components(food.absorptionTime)
        setAbsorptionTime(hours: components.hours, minutes: components.minutes)
        selectedFavoriteFoodID = food.id
        selectedPortionID = portion.id
    }

    private func clearFavoriteSelection() {
        selectedFavoriteFoodID = nil
        selectedPortionID = nil
        carbsAmount = HKQuantity(unit: .gram(), doubleValue: 0)
        foodEmoji = ""
        foodName = ""
        let components = FavoriteFoodAbsorption.components(FavoriteFoodAbsorption.default)
        setAbsorptionTime(hours: components.hours, minutes: components.minutes)
    }
}
