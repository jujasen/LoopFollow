// LoopFollow
// FavoriteFoodSyncService.swift

import Combine
import Foundation

/// Keeps the favorite foods on this phone in step with Loop's, through Nightscout's food
/// collection. See `FavoriteFoodSyncDocument` for the shared document, and
/// `FavoriteFoodSyncEngine` for the rules that decide which side is newer.
@MainActor
final class FavoriteFoodSyncService: ObservableObject {
    static let shared = FavoriteFoodSyncService()

    enum Status: Equatable {
        case off
        case idle(lastSync: Date?)
        case syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    /// Coalesces the bursts that follow an edit — the store writes foods, folders and
    /// tombstones separately, and each of those pokes the sync.
    private var pendingSync: Task<Void, Never>?
    private var isSyncing = false

    private init() {
        status = Self.isConfigured ? .idle(lastSync: Storage.shared.favoriteFoodLastSync.value) : .off
    }

    static var isConfigured: Bool {
        Storage.shared.favoriteFoodSyncEnabled.value
            && !Storage.shared.favoriteFoodSyncToken.value.isEmpty
            && !Storage.shared.url.value.isEmpty
    }

    /// Syncs after a short delay, so a handful of edits in a row travel as one round trip.
    func syncSoon(delay: TimeInterval = 2) {
        guard Self.isConfigured else { return }

        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    @discardableResult
    func sync() async -> Bool {
        guard Self.isConfigured else {
            status = .off
            return false
        }
        guard !isSyncing else { return false }

        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        let api = NightscoutFoodAPI(
            baseURL: Storage.shared.url.value,
            token: Storage.shared.favoriteFoodSyncToken.value
        )

        do {
            let documents = try await api.fetch()
            let remote = documents.compactMap(FavoriteFoodSyncDocument.parse)

            let outcome = FavoriteFoodSyncEngine.merge(
                .init(
                    foods: FavoriteFoodsStore.foods,
                    folders: FavoriteFoodsStore.folders,
                    tombstones: FavoriteFoodsStore.tombstones,
                    remote: remote,
                    // Nightscout's food endpoint returns the whole collection, so anything
                    // missing from it really is gone.
                    remoteIsComplete: true,
                    now: Date()
                )
            )

            FavoriteFoodsStore.applySynced(
                foods: outcome.foods,
                folders: outcome.folders,
                tombstones: outcome.tombstones
            )

            let rawByNSID = Dictionary(remote.map { ($0.nsID, $0.raw) }, uniquingKeysWith: { first, _ in first })
            try await push(outcome: outcome, rawByNSID: rawByNSID, api: api)

            let now = Date()
            Storage.shared.favoriteFoodLastSync.value = now
            status = .idle(lastSync: now)
            LogManager.shared.log(
                category: .nightscout,
                message: "Favorite foods synced: \(outcome.foods.count) local, \(outcome.creates.count) created, \(outcome.updates.count) updated, \(outcome.deletions.count) deleted",
                isDebug: true
            )
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            LogManager.shared.log(category: .nightscout, message: "Favorite food sync failed: \(message)")
            return false
        }
    }

    // MARK: - Writing back

    private func push(outcome: FavoriteFoodSyncEngine.Outcome, rawByNSID: [String: [String: Any]], api: NightscoutFoodAPI) async throws {
        let folders = FavoriteFoodsStore.folders

        func folder(for food: StoredFavoriteFood) -> FavoriteFoodFolder? {
            folders.first(where: { $0.id == food.folderID })
        }

        if !outcome.creates.isEmpty {
            let documents = outcome.creates.map { FavoriteFoodSyncDocument.document(for: $0, folder: folder(for: $0)) }
            let created = try await api.create(documents)

            // Remember each new document id, so the next sync updates instead of duplicating.
            var stored = FavoriteFoodsStore.foods
            for document in created {
                guard let nsID = document["_id"] as? String,
                      let block = document[FavoriteFoodSyncDocument.blockKey] as? [String: Any],
                      let id = block["id"] as? String,
                      let index = stored.firstIndex(where: { $0.id == id })
                else { continue }
                stored[index].nsID = nsID
            }
            if stored != FavoriteFoodsStore.foods {
                FavoriteFoodsStore.applySynced(foods: stored, folders: folders, tombstones: FavoriteFoodsStore.tombstones)
            }
        }

        for food in outcome.updates {
            guard let nsID = food.nsID else { continue }
            var document = FavoriteFoodSyncDocument.document(for: food, folder: folder(for: food), base: rawByNSID[nsID])
            document["_id"] = nsID
            try await api.update(document)
        }

        var remainingTombstones = FavoriteFoodsStore.tombstones
        for tombstone in outcome.deletions {
            guard let nsID = tombstone.nsID,
                  let raw = rawByNSID[nsID],
                  let parsed = FavoriteFoodSyncDocument.parse(raw)
            else { continue }

            var document = FavoriteFoodSyncDocument.document(
                for: parsed.food,
                folder: parsed.folder,
                deletedAt: tombstone.deletedAt,
                base: raw
            )
            document["_id"] = nsID
            try await api.update(document)

            // Nightscout now carries the deletion, so this phone no longer has to.
            remainingTombstones.removeAll(where: { $0.id == tombstone.id })
        }
        if remainingTombstones != FavoriteFoodsStore.tombstones {
            FavoriteFoodsStore.applySynced(
                foods: FavoriteFoodsStore.foods,
                folders: folders,
                tombstones: remainingTombstones
            )
        }

        for nsID in outcome.purges {
            try await api.delete(nsID)
        }
    }

    // MARK: - Setup

    /// Turns sync on by provisioning a Nightscout token that may write the food collection.
    /// The API secret is used for this one call and is not stored.
    func enableSync(apiSecret: String) async throws {
        let token = try await NightscoutUtils.provisionFoodSyncToken(
            url: Storage.shared.url.value,
            secret: apiSecret
        )
        Storage.shared.favoriteFoodSyncToken.value = token
        Storage.shared.favoriteFoodSyncEnabled.value = true
        status = .idle(lastSync: Storage.shared.favoriteFoodLastSync.value)
        await sync()
    }

    func disableSync() {
        pendingSync?.cancel()
        Storage.shared.favoriteFoodSyncEnabled.value = false
        status = .off
    }
}

/// The bit of Nightscout's v1 API that stores food. The endpoint has no `.json` alias, and its
/// list route returns the whole collection.
struct NightscoutFoodAPI {
    enum APIError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Nightscout address or token is missing."
            case let .http(status, body):
                switch status {
                case 401, 403:
                    return "Nightscout rejected the food token (\(status)). Set the sync up again with your API secret."
                case 404:
                    return "This Nightscout site has no food API."
                default:
                    return "Nightscout returned \(status). \(body)"
                }
            }
        }
    }

    let baseURL: String
    let token: String

    private func request(path: String, method: String) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !token.isEmpty,
              var components = URLComponents(string: trimmed)
        else { throw APIError.notConfigured }

        components.path = (components.path as NSString).appendingPathComponent(path)
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let url = components.url else { throw APIError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, String(body.prefix(200)))
        }
        return data
    }

    func fetch() async throws -> [[String: Any]] {
        let data = try await send(request(path: "/api/v1/food/", method: "GET"))
        return try (JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Creates documents and returns them as stored, so the caller learns their `_id`s.
    func create(_ documents: [[String: Any]]) async throws -> [[String: Any]] {
        guard !documents.isEmpty else { return [] }
        var request = try request(path: "/api/v1/food/", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: documents)

        let data = try await send(request)
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [single]
        }
        return []
    }

    func update(_ document: [String: Any]) async throws {
        var request = try request(path: "/api/v1/food/", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: document)
        _ = try await send(request)
    }

    func delete(_ nsID: String) async throws {
        _ = try await send(request(path: "/api/v1/food/\(nsID)", method: "DELETE"))
    }
}
