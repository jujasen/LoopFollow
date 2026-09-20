// LoopFollow
// FavoriteFoodsView.swift

import SwiftUI

/// The list where favorite foods are created, edited, reordered, filed and deleted.
/// Reached from the carb screen and from Remote Settings.
struct FavoriteFoodsView: View {
    @ObservedObject private var storedFoods = Storage.shared.favoriteFoods
    @ObservedObject private var storedFolders = Storage.shared.favoriteFoodFolders
    @ObservedObject private var syncService = FavoriteFoodSyncService.shared

    @State private var searchText = ""
    @State private var isAddingFood = false
    @State private var addToFolderID: String?
    @State private var folderEditorTarget: FolderEditorTarget?
    @State private var isShowingSyncSettings = false

    private var sections: [FavoriteFoodSection] {
        FavoriteFoodsStore.sections(searchQuery: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasNoMatches: Bool {
        isSearching && sections.allSatisfy { $0.foods.isEmpty }
    }

    var body: some View {
        List {
            if storedFoods.value.isEmpty, storedFolders.value.isEmpty {
                Section {
                    emptyState
                }
            } else if hasNoMatches {
                Section {
                    noMatchesState
                }
            } else {
                ForEach(sections) { section in
                    Section(header: sectionHeader(for: section)) {
                        if section.foods.isEmpty {
                            Text(section.isUnfiled ? "No foods outside a folder." : "This folder is empty.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        ForEach(section.foods) { food in
                            NavigationLink {
                                AddEditFavoriteFoodView(food: food)
                            } label: {
                                FavoriteFoodRow(food: food)
                            }
                            .contextMenu {
                                moveMenuItems(for: food)
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets, in: section)
                        }
                        .onMove { from, to in
                            FavoriteFoodsStore.reorder(in: section, from: from, to: to)
                        }
                        .moveDisabled(isSearching)
                    }
                }
            }

            Section {
                Button {
                    addToFolderID = nil
                    isAddingFood = true
                } label: {
                    Label("Add a new favorite food", systemImage: "plus.circle.fill")
                }

                Button {
                    folderEditorTarget = .new
                } label: {
                    Label("Add a folder", systemImage: "folder.badge.plus")
                }
            }

            syncSection
        }
        .searchable(text: $searchText, prompt: "Search foods")
        .navigationTitle("Favorite Foods")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !storedFoods.value.isEmpty {
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $isAddingFood) {
            NavigationStack {
                AddEditFavoriteFoodView(initialFolderID: addToFolderID)
            }
        }
        .sheet(item: $folderEditorTarget) { target in
            FavoriteFoodFolderEditorView(folder: target.folder)
        }
        .sheet(isPresented: $isShowingSyncSettings) {
            FavoriteFoodSyncSettingsView()
        }
        .task {
            // Opening the list is the moment to show what Loop has been up to.
            await syncService.sync()
        }
    }

    /// Sharing with Loop, and how it is doing.
    private var syncSection: some View {
        Section {
            Button {
                isShowingSyncSettings = true
            } label: {
                HStack {
                    Label("Share with Loop", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    syncStatusText
                        .font(.footnote)
                        .foregroundColor(syncStatusIsError ? .red : .secondary)
                }
            }
        } footer: {
            Text("Shares this list with Loop through your Nightscout site, so both phones hold the same favorites.")
        }
    }

    @ViewBuilder
    private var syncStatusText: some View {
        switch syncService.status {
        case .off:
            Text("Off")
        case .syncing:
            Text("Syncing…")
        case let .idle(lastSync):
            if let lastSync {
                Text(lastSync, format: .dateTime.hour().minute())
            } else {
                Text("On")
            }
        case .failed:
            Text("Failed")
        }
    }

    private var syncStatusIsError: Bool {
        if case .failed = syncService.status { return true }
        return false
    }

    private func delete(_ offsets: IndexSet, in section: FavoriteFoodSection) {
        for index in offsets where section.foods.indices.contains(index) {
            FavoriteFoodsStore.delete(section.foods[index])
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("Picking a favorite food on the carb screen fills in the carb amount, food type and absorption time for you. Tap below to create your first favorite food.")

            Text("Give each food a name and a serving size — like “1 bowl” — and file it in a folder to keep your list tidy.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No matching foods")
                .font(.body.weight(.semibold))

            Text("Try a different name or serving size.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(for section: FavoriteFoodSection) -> some View {
        HStack(spacing: 8) {
            Text(sectionTitle(for: section))
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
                .foregroundColor(.primary)

            if !section.foods.isEmpty {
                Text("\(section.foods.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }

            Spacer()

            if let folder = section.folder {
                folderMenu(for: folder)
            }
        }
    }

    private func sectionTitle(for section: FavoriteFoodSection) -> String {
        if let folder = section.folder {
            return folder.title
        }
        return storedFolders.value.isEmpty ? "All Favorites" : "Not in a Folder"
    }

    private func folderMenu(for folder: FavoriteFoodFolder) -> some View {
        Menu {
            Button {
                addToFolderID = folder.id
                isAddingFood = true
            } label: {
                Label("Add Food Here", systemImage: "plus")
            }

            Button {
                folderEditorTarget = .existing(folder)
            } label: {
                Label("Edit Folder", systemImage: "pencil")
            }

            Button(role: .destructive) {
                FavoriteFoodsStore.deleteFolder(folder)
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundColor(.accentColor)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private func moveMenuItems(for food: StoredFavoriteFood) -> some View {
        if !storedFolders.value.isEmpty {
            Text("Move to")

            Button {
                FavoriteFoodsStore.move(food, toFolderID: nil)
            } label: {
                Label("No Folder", systemImage: "tray")
            }

            ForEach(storedFolders.value) { folder in
                Button {
                    FavoriteFoodsStore.move(food, toFolderID: folder.id)
                } label: {
                    Label(folder.title, systemImage: "folder")
                }
            }
        }
    }

    private enum FolderEditorTarget: Identifiable {
        case new
        case existing(FavoriteFoodFolder)

        var id: String {
            switch self {
            case .new: return "new"
            case let .existing(folder): return folder.id
            }
        }

        var folder: FavoriteFoodFolder? {
            switch self {
            case .new: return nil
            case let .existing(folder): return folder
            }
        }
    }
}

/// Create, rename or delete a favorite food folder.
struct FavoriteFoodFolderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existingFolder: FavoriteFoodFolder?

    @State private var name: String
    @State private var emoji: String
    @State private var isConfirmingDelete = false

    init(folder: FavoriteFoodFolder?) {
        existingFolder = folder
        _name = State(initialValue: folder?.name ?? "")
        _emoji = State(initialValue: folder?.emoji ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Breakfast", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Icon")
                        Spacer()
                        TextField("🥣", text: $emoji)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: emoji) { _, newValue in
                                // A folder icon is a single character.
                                emoji = String(newValue.suffix(1))
                            }
                    }
                } footer: {
                    Text("Folders are optional. Deleting a folder keeps its foods — they simply move back out of the folder.")
                }

                if let existingFolder {
                    Section {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Text("Delete Folder")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert("Delete “\(existingFolder.name)”?", isPresented: $isConfirmingDelete) {
                            Button("Cancel", role: .cancel) {}
                            Button("Delete", role: .destructive) {
                                FavoriteFoodsStore.deleteFolder(existingFolder)
                                dismiss()
                            }
                        } message: {
                            Text("The foods in this folder will be kept and moved out of the folder.")
                        }
                    }
                }
            }
            .navigationTitle(existingFolder == nil ? "New Folder" : "Edit Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var folder = existingFolder ?? FavoriteFoodFolder(name: trimmedName)
        folder.name = trimmedName
        folder.emoji = emoji
        FavoriteFoodsStore.saveFolder(folder)
        dismiss()
    }
}
