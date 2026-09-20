// LoopFollow
// FavoriteFoodSyncTask.swift

import Foundation

extension MainViewController {
    /// Picks up favorite foods edited in Loop. Edits made here push straight away
    /// (`FavoriteFoodSyncService.syncSoon`), so this is only the pull side and can be lazy.
    func scheduleFavoriteFoodSyncTask(initialDelay: TimeInterval = 20) {
        TaskScheduler.shared.scheduleTask(id: .favoriteFoodSync, nextRun: Date().addingTimeInterval(initialDelay)) {
            Task { @MainActor in
                await FavoriteFoodSyncService.shared.sync()
            }
            TaskScheduler.shared.rescheduleTask(
                id: .favoriteFoodSync,
                to: Date().addingTimeInterval(FavoriteFoodSyncService.isConfigured ? 15 * 60 : 5 * 60)
            )
        }
    }
}
