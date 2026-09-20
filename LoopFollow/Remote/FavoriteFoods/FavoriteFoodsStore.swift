// LoopFollow
// FavoriteFoodsStore.swift

import Foundation
import SwiftUI

/// Every change to the favorite foods list goes through here, so the stored order, the folder
/// memberships and the views that observe `Storage.shared.favoriteFoods` stay in step.
enum FavoriteFoodsStore {
    // MARK: - Reading

    static var foods: [StoredFavoriteFood] {
        get { Storage.shared.favoriteFoods.value }
        set { Storage.shared.favoriteFoods.value = newValue }
    }

    static var folders: [FavoriteFoodFolder] {
        get { Storage.shared.favoriteFoodFolders.value }
        set { Storage.shared.favoriteFoodFolders.value = newValue }
    }

    static func folder(withID id: String?) -> FavoriteFoodFolder? {
        guard let id else { return nil }
        return folders.first(where: { $0.id == id })
    }

    /// A food's folder, ignoring stale references to folders that no longer exist.
    static func resolvedFolderID(for food: StoredFavoriteFood, in folders: [FavoriteFoodFolder]) -> String? {
        guard let folderID = food.folderID, folders.contains(where: { $0.id == folderID }) else {
            return nil
        }
        return folderID
    }

    static func resolvedFolderID(for food: StoredFavoriteFood) -> String? {
        resolvedFolderID(for: food, in: folders)
    }

    static func foodCount(in folder: FavoriteFoodFolder) -> Int {
        foods.filter { $0.folderID == folder.id }.count
    }

    /// Foods grouped by folder, folders first in their stored order and unfiled foods last.
    /// Empty sections are kept so that a folder you just made is visible and can be filled.
    ///
    /// - Parameters:
    ///   - searchQuery: only foods matching this are included; empty means everything.
    ///   - includeEmptySections: false when browsing to pick a food, where an empty folder is noise.
    static func sections(searchQuery: String = "", includeEmptySections: Bool = true) -> [FavoriteFoodSection] {
        sections(foods: foods, folders: folders, searchQuery: searchQuery, includeEmptySections: includeEmptySections)
    }

    /// The grouping itself, free of storage so it can be tested and reused.
    static func sections(foods: [StoredFavoriteFood], folders: [FavoriteFoodFolder], searchQuery: String = "", includeEmptySections: Bool = true) -> [FavoriteFoodSection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? foods : foods.filter { $0.matches(searchQuery: query) }

        var sections = folders
            .map { folder in
                FavoriteFoodSection(folder: folder, foods: matching.filter { resolvedFolderID(for: $0, in: folders) == folder.id })
            }
            .filter { includeEmptySections || !$0.foods.isEmpty }

        let unfiled = matching.filter { resolvedFolderID(for: $0, in: folders) == nil }
        if !unfiled.isEmpty || (includeEmptySections && folders.isEmpty) {
            sections.append(FavoriteFoodSection(folder: nil, foods: unfiled))
        }
        return sections
    }

    // MARK: - Foods

    static var tombstones: [FavoriteFoodTombstone] {
        get { Storage.shared.favoriteFoodTombstones.value }
        set { Storage.shared.favoriteFoodTombstones.value = newValue }
    }

    /// Adds a new food, or replaces the stored one with the same id.
    ///
    /// The edit is stamped with the current time so Nightscout can tell which side changed last;
    /// saving a food without changing anything leaves the stamp alone.
    static func save(_ food: StoredFavoriteFood) {
        var updated = food
        if let existing = foods.first(where: { $0.id == food.id }) {
            updated.nsID = food.nsID ?? existing.nsID
            if existing.hasSameContent(as: updated) {
                updated.updatedAt = existing.updatedAt
            } else {
                updated.updatedAt = Date()
            }
        } else {
            updated.updatedAt = Date()
        }

        withAnimation {
            if let index = foods.firstIndex(where: { $0.id == updated.id }) {
                foods[index] = updated
            } else {
                foods.append(updated)
            }
            tombstones.removeAll(where: { $0.id == updated.id })
        }
        scheduleSync()
    }

    static func delete(_ food: StoredFavoriteFood) {
        withAnimation {
            foods.removeAll(where: { $0.id == food.id })
            tombstones.removeAll(where: { $0.id == food.id })
            tombstones.append(FavoriteFoodTombstone(id: food.id, nsID: food.nsID))
        }
        scheduleSync()
    }

    static func move(_ food: StoredFavoriteFood, toFolderID folderID: String?) {
        guard let index = foods.firstIndex(where: { $0.id == food.id }), foods[index].folderID != folderID else { return }
        withAnimation {
            foods[index].folderID = folderID
            foods[index].updatedAt = Date()
        }
        scheduleSync()
    }

    /// Nudges the Nightscout sync after a local edit. It waits a moment first, so a burst of
    /// edits travels as one round trip, and does nothing when sync is off.
    private static func scheduleSync() {
        Task { @MainActor in
            FavoriteFoodSyncService.shared.syncSoon()
        }
    }

    /// Reorders within one section, mapping the section-local move back onto the flat store so
    /// that the order shown in the carb screen follows along. Order is local to this device —
    /// Nightscout has no notion of it — so a move is not stamped as an edit.
    static func reorder(in section: FavoriteFoodSection, from: IndexSet, to: Int) {
        let updated = reordered(foods: foods, folders: folders, in: section, from: from, to: to)
        guard updated != foods else { return }
        withAnimation {
            foods = updated
        }
    }

    /// The reordering itself, free of storage so it can be tested and reused.
    static func reordered(foods: [StoredFavoriteFood], folders: [FavoriteFoodFolder], in section: FavoriteFoodSection, from: IndexSet, to: Int) -> [StoredFavoriteFood] {
        var reordered = section.foods
        reordered.move(fromOffsets: from, toOffset: to)

        let positions = foods.indices.filter { resolvedFolderID(for: foods[$0], in: folders) == section.folder?.id }
        guard positions.count == reordered.count else { return foods }

        var updated = foods
        for (position, food) in zip(positions, reordered) {
            updated[position] = food
        }
        return updated
    }

    // MARK: - Applying what the sync brought back

    /// Replaces the stored foods, folders and tombstones in one write. Used by the Nightscout
    /// sync, which has already decided — per food — which side is newer, so nothing is stamped.
    static func applySynced(foods newFoods: [StoredFavoriteFood], folders newFolders: [FavoriteFoodFolder], tombstones newTombstones: [FavoriteFoodTombstone]) {
        withAnimation {
            if foods != newFoods { foods = newFoods }
            if folders != newFolders { folders = newFolders }
            if tombstones != newTombstones { tombstones = newTombstones }
        }
    }

    // MARK: - Folders

    /// Saves a folder, and stamps the foods in it when the name or emoji changed: a folder only
    /// travels to Nightscout as part of the foods filed in it, so a rename rides along with them.
    static func saveFolder(_ folder: FavoriteFoodFolder) {
        let previous = folders.first(where: { $0.id == folder.id })
        withAnimation {
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index] = folder
            } else {
                folders.append(folder)
            }

            if let previous, previous != folder {
                stampFoods(inFolder: folder.id)
            }
        }
        scheduleSync()
    }

    /// Deleting a folder never deletes food: everything inside becomes unfiled.
    static func deleteFolder(_ folder: FavoriteFoodFolder) {
        withAnimation {
            var updated = foods
            let now = Date()
            for index in updated.indices where updated[index].folderID == folder.id {
                updated[index].folderID = nil
                updated[index].updatedAt = now
            }
            foods = updated
            folders.removeAll(where: { $0.id == folder.id })
        }
        scheduleSync()
    }

    static func reorderFolders(from: IndexSet, to: Int) {
        withAnimation {
            folders.move(fromOffsets: from, toOffset: to)
        }
    }

    private static func stampFoods(inFolder folderID: String) {
        var updated = foods
        let now = Date()
        for index in updated.indices where updated[index].folderID == folderID {
            updated[index].updatedAt = now
        }
        foods = updated
    }
}
