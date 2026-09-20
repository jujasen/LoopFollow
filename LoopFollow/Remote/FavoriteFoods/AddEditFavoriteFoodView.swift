// LoopFollow
// AddEditFavoriteFoodView.swift

import HealthKit
import SwiftUI

/// Create or edit one favorite food: its name, the amounts it can be sent at, its emoji,
/// its absorption time and the folder it is filed in.
struct AddEditFavoriteFoodView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storedFolders = Storage.shared.favoriteFoodFolders

    /// The food being edited, or nil when creating a new one.
    private let originalFood: StoredFavoriteFood?
    /// True when this screen was presented as a sheet and needs its own Cancel button.
    private let isModal: Bool

    @State private var name: String
    @State private var foodType: String
    @State private var absorptionHours: Int
    @State private var absorptionMinutes: Int
    @State private var portions: [FavoriteFoodPortion]
    @State private var folderID: String?
    @State private var isConfirmingDelete = false

    /// Emoji offered as one tap each, matching the ones the carb screen uses plus a few common meals.
    private static let quickEmojis = ["🍭", "🍎", "🥣", "🍞", "🥪", "🍝", "🌮", "🍕", "🍟", "🍫", "🍽️"]

    private let maxPortions = 8

    /// Edit an existing food. Pushed onto the favorites list, so it has a back button already.
    init(food: StoredFavoriteFood) {
        originalFood = food
        isModal = false
        _name = State(initialValue: food.name)
        _foodType = State(initialValue: food.foodType)
        let components = FavoriteFoodAbsorption.components(food.absorptionTime)
        _absorptionHours = State(initialValue: components.hours)
        _absorptionMinutes = State(initialValue: components.minutes)
        _portions = State(initialValue: food.portions)
        _folderID = State(initialValue: food.folderID)
    }

    /// Create a new food, optionally pre-filled from what is already typed on the carb screen.
    init(initialFolderID: String? = nil, carbs: Double? = nil, foodType: String = "", absorptionTime: TimeInterval? = nil) {
        originalFood = nil
        isModal = true
        _name = State(initialValue: "")
        _foodType = State(initialValue: foodType)
        let components = FavoriteFoodAbsorption.components(absorptionTime ?? FavoriteFoodAbsorption.default)
        _absorptionHours = State(initialValue: components.hours)
        _absorptionMinutes = State(initialValue: components.minutes)
        _portions = State(initialValue: [FavoriteFoodPortion(carbs: carbs ?? 0)])
        _folderID = State(initialValue: initialFolderID)
    }

    // MARK: - Derived state

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var absorptionTime: TimeInterval {
        FavoriteFoodAbsorption.timeInterval(hours: absorptionHours, minutes: absorptionMinutes)
    }

    private var validPortions: [FavoriteFoodPortion] {
        portions
            .map { FavoriteFoodPortion(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), carbs: $0.carbs) }
            .filter { $0.carbs > 0 }
    }

    private var maxCarbs: Double {
        Storage.shared.maxCarbs.value.doubleValue(for: .gram())
    }

    private var portionsOverGuardrail: [FavoriteFoodPortion] {
        validPortions.filter { $0.carbs > maxCarbs }
    }

    private var saveDisabledReason: String? {
        if trimmedName.isEmpty {
            return "Give the food a name."
        }
        if validPortions.isEmpty {
            return "Enter the carbs for at least one serving size."
        }
        return nil
    }

    private var absorptionHourOptions: [Int] {
        Array(0 ... Int(FavoriteFoodAbsorption.maximum / 3600))
    }

    private var absorptionMinuteOptions: [Int] {
        if absorptionHours == 0 {
            return [Int(FavoriteFoodAbsorption.minimum / 60)]
        }
        if absorptionHours == Int(FavoriteFoodAbsorption.maximum / 3600) {
            return [0]
        }
        return [0, 30]
    }

    // MARK: - Body

    var body: some View {
        Form {
            nameSection

            servingSizesSection

            absorptionSection

            if !storedFolders.value.isEmpty {
                Section(header: Text("Folder")) {
                    Picker("Folder", selection: $folderID) {
                        Text("No Folder").tag(String?.none)
                        ForEach(storedFolders.value) { folder in
                            Text(folder.title).tag(String?.some(folder.id))
                        }
                    }
                }
            }

            if let saveDisabledReason {
                Section {
                    Text(saveDisabledReason)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            if originalFood != nil {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Text("Delete Food")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle(originalFood == nil ? "New Favorite Food" : (originalFood?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(saveDisabledReason != nil)
            }
        }
        .alert("Delete “\(originalFood?.name ?? "")”?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let originalFood {
                    FavoriteFoodsStore.delete(originalFood)
                }
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete this food?")
        }
    }

    private var nameSection: some View {
        Section {
            HStack {
                Text("Name")
                Spacer()
                TextField("Apple", text: $name)
                    .multilineTextAlignment(.trailing)
            }

            foodTypeRow
        }
    }

    private var foodTypeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Food Type")
                Spacer()
                TextField("🍎", text: $foodType)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .onChange(of: foodType) { _, newValue in
                        // The food type is a single emoji, as in Loop.
                        foodType = String(newValue.suffix(1))
                    }
            }

            emojiQuickPicks
        }
    }

    private var emojiQuickPicks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.quickEmojis, id: \.self) { emoji in
                    Button {
                        foodType = foodType == emoji ? "" : emoji
                    } label: {
                        emojiTile(emoji)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func emojiTile(_ emoji: String) -> some View {
        Text(emoji)
            .font(.title3)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(foodType == emoji ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill))
            )
    }

    private var absorptionSection: some View {
        Section {
            HStack {
                Text("Absorption Time")

                Spacer()

                Picker("Hours", selection: $absorptionHours) {
                    ForEach(absorptionHourOptions, id: \.self) { hour in
                        Text("\(hour) hr").tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("Minutes", selection: $absorptionMinutes) {
                    ForEach(absorptionMinuteOptions, id: \.self) { minute in
                        Text("\(minute) min").tag(minute)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .onChange(of: absorptionHours) { _, _ in
                normalizeAbsorptionMinutes()
            }
        } footer: {
            Text("Choose how long this meal usually takes to absorb — 30 minutes up to 8 hours, the same range the carb screen sends with.")
        }
    }

    private var servingSizesSection: some View {
        Section {
            ForEach($portions) { $portion in
                HStack(spacing: 8) {
                    TextField(portionNamePlaceholder, text: $portion.name)

                    TextField("0", value: $portion.carbs, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)

                    Text("g")
                        .foregroundColor(.secondary)
                }
            }
            .onDelete { offsets in
                guard portions.count > 1 else { return }
                portions.remove(atOffsets: offsets)
            }

            if portions.count < maxPortions {
                Button {
                    portions.append(FavoriteFoodPortion(carbs: 0))
                } label: {
                    Label("Add a serving size", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
            }
        } header: {
            HStack {
                Text("Serving Size")
                Spacer()
                Text("Carbs")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if portions.count > 1 {
                    Text("Naming each amount makes it easier to tell them apart when sending carbs. The first one is used when you tap the food without choosing an amount.")
                } else {
                    Text("A serving size is optional — “1 bowl”, “half a slice”. Add more than one to save the same food at several amounts.")
                }

                if let overGuardrail = portionsOverGuardrail.first {
                    Text("\(overGuardrail.carbsString) is above your max carbs guardrail of \(FavoriteFoodFormatters.carbs(maxCarbs)). You can save it, but sending it will be blocked until you raise the guardrail in Remote Settings.")
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var portionNamePlaceholder: String {
        portions.count > 1 ? "1 slice" : "Serving size (optional)"
    }

    private func normalizeAbsorptionMinutes() {
        if !absorptionMinuteOptions.contains(absorptionMinutes) {
            absorptionMinutes = absorptionMinuteOptions.first ?? 0
        }
    }

    private func save() {
        guard saveDisabledReason == nil else { return }

        let food = StoredFavoriteFood(
            id: originalFood?.id ?? UUID().uuidString,
            name: trimmedName,
            portions: validPortions,
            foodType: foodType,
            absorptionTime: absorptionTime,
            folderID: folderID
        )
        FavoriteFoodsStore.save(food)
        dismiss()
    }
}
