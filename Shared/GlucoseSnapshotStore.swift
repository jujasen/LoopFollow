// LoopFollow
// GlucoseSnapshotStore.swift

import Foundation
import WidgetKit

/// Persists the latest GlucoseSnapshot into the App Group container so that:
/// - the Live Activity extension can read it
/// - the lock screen widget can read it
/// - future Watch + CarPlay surfaces can reuse it
///
/// Uses an atomic JSON file write to avoid partial/corrupt reads across processes.
final class GlucoseSnapshotStore {
    static let shared = GlucoseSnapshotStore()
    private init() {}

    private let fileName = "glucose_snapshot.json"
    private let queue = DispatchQueue(label: "com.loopfollow.glucoseSnapshotStore", qos: .utility)

    /// Payload of the most recent widget reload, used to avoid spending WidgetKit's
    /// reload budget on saves that would render identically. Only ever touched on
    /// `queue`.
    private var lastReloadedData: Data?

    // MARK: - Public API

    func save(_ snapshot: GlucoseSnapshot) {
        queue.async {
            do {
                let url = try self.fileURL()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])

                // The widget cannot fetch on its own, so this is the only thing that
                // brings a new reading to the lock screen.
                if data != self.lastReloadedData {
                    self.lastReloadedData = data
                    WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.lockScreen)
                }
            } catch {
                // Intentionally silent (extension-safe, no dependencies).
            }
        }
    }

    func load() -> GlucoseSnapshot? {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GlucoseSnapshot.self, from: data)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    func delete() {
        queue.async {
            do {
                let url = try self.fileURL()
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                // Intentionally silent (extension-safe, no dependencies).
            }
        }
    }

    // MARK: - Helpers

    private func fileURL() throws -> URL {
        let groupID = AppGroupID.current()
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(
                domain: "GlucoseSnapshotStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group containerURL is nil for id=\(groupID)"],
            )
        }
        return containerURL.appendingPathComponent(fileName, isDirectory: false)
    }
}
