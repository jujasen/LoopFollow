// LoopFollow
// FavoriteFoodViews.swift

import SwiftUI

/// The emoji a favorite food was saved with, shown on a soft tinted tile.
struct FavoriteFoodEmojiTile: View {
    let emoji: String
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))

            if emoji.isEmpty {
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundColor(.accentColor)
            } else {
                Text(emoji)
                    .font(.system(size: size * 0.48))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One favorite food as a list row: emoji, name, serving size and a carbs/absorption summary.
struct FavoriteFoodRow: View {
    let food: StoredFavoriteFood
    var tileSize: CGFloat = 42

    var body: some View {
        HStack(spacing: 12) {
            FavoriteFoodEmojiTile(emoji: food.foodType, size: tileSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(food.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)

                if food.hasServingSize {
                    Text(food.servingSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text(food.summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// A compact, one-tap representation of a favorite food used in the carb screen.
struct FavoriteFoodChip: View {
    let food: StoredFavoriteFood
    let selectedPortion: FavoriteFoodPortion?
    let isSelected: Bool

    private let cornerRadius: CGFloat = 14

    private var subtitle: String? {
        if let selectedPortion, selectedPortion.hasName {
            return selectedPortion.name
        }
        if food.hasMultiplePortions {
            return "\(food.portions.count) sizes"
        }
        return food.hasServingSize ? food.servingSize : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if food.foodType.isEmpty {
                Image(systemName: "fork.knife")
                    .font(.footnote)
                    .foregroundColor(.accentColor)
            } else {
                Text(food.foodType)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(food.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if isSelected {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if food.hasMultiplePortions {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A searchable, folder-grouped list for choosing a favorite food, presented from the carb screen.
struct FavoriteFoodPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storedFoods = Storage.shared.favoriteFoods
    @ObservedObject private var storedFolders = Storage.shared.favoriteFoodFolders

    let selectedFood: StoredFavoriteFood?
    let onSelect: (StoredFavoriteFood?, FavoriteFoodPortion?) -> Void

    @State private var searchText = ""

    private var sections: [FavoriteFoodSection] {
        FavoriteFoodsStore.sections(searchQuery: searchText, includeEmptySections: false)
    }

    var body: some View {
        NavigationStack {
            List {
                if selectedFood != nil {
                    Section {
                        Button(role: .destructive) {
                            onSelect(nil, nil)
                            dismiss()
                        } label: {
                            Label("Clear selection", systemImage: "xmark.circle")
                        }
                    }
                }

                if sections.isEmpty {
                    Section {
                        Text(storedFoods.value.isEmpty ? "You have no favorite foods yet." : "No matching foods")
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(sections) { section in
                    Section(header: Text(sectionTitle(for: section))) {
                        ForEach(section.foods) { food in
                            foodRows(for: food)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search foods")
            .navigationTitle("Favorite Foods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// A food with several amounts lists each amount as its own tappable row, so picking
    /// "half a slice" never needs a second screen.
    @ViewBuilder
    private func foodRows(for food: StoredFavoriteFood) -> some View {
        if food.hasMultiplePortions {
            DisclosureGroup {
                ForEach(food.portions) { portion in
                    Button {
                        onSelect(food, portion)
                        dismiss()
                    } label: {
                        HStack {
                            Text(portion.summary)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedFood?.id == food.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } label: {
                FavoriteFoodRow(food: food, tileSize: 38)
            }
        } else {
            Button {
                onSelect(food, food.defaultPortion)
                dismiss()
            } label: {
                HStack {
                    FavoriteFoodRow(food: food, tileSize: 38)
                    if selectedFood?.id == food.id {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }

    private func sectionTitle(for section: FavoriteFoodSection) -> String {
        if let folder = section.folder {
            return folder.title
        }
        return storedFolders.value.isEmpty ? "All Favorites" : "Not in a Folder"
    }
}
