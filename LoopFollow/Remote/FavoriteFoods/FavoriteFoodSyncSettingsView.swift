// LoopFollow
// FavoriteFoodSyncSettingsView.swift

import SwiftUI

/// Sets up sharing favorite foods with Loop through Nightscout, and shows how the sharing is
/// doing afterwards.
struct FavoriteFoodSyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = FavoriteFoodSyncService.shared
    @ObservedObject private var nightscoutURL = Storage.shared.url

    @State private var apiSecret = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isEnabled: Bool {
        Storage.shared.favoriteFoodSyncEnabled.value && !Storage.shared.favoriteFoodSyncToken.value.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Loop and LoopFollow keep the same favorite foods, through the food list on your Nightscout site. Edit a food here and Loop picks it up; edit it in Loop and it turns up here.")
                } header: {
                    Text("Share with Loop")
                } footer: {
                    Text("Loop needs a build that shares its favorites too — an older build ignores the food list.")
                }

                if nightscoutURL.value.isEmpty {
                    Section {
                        Text("Set up your Nightscout address first, under Settings → Nightscout.")
                            .foregroundColor(.secondary)
                    }
                } else if isEnabled {
                    enabledSection
                } else {
                    setupSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Share Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var setupSection: some View {
        Section {
            SecureField("API secret", text: $apiSecret)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button {
                enable()
            } label: {
                HStack {
                    if isWorking {
                        ProgressView()
                            .padding(.trailing, 6)
                    }
                    Text(isWorking ? "Setting up…" : "Turn on sharing")
                }
            }
            .disabled(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
        } header: {
            Text("Nightscout API secret")
        } footer: {
            Text("The secret is used once, to create a Nightscout token that may read and write the food list. LoopFollow stores that token — never the secret itself.")
        }
    }

    private var enabledSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                statusText
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                Task {
                    isWorking = true
                    await service.sync()
                    isWorking = false
                }
            } label: {
                Label(isWorking ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isWorking)

            Button(role: .destructive) {
                service.disableSync()
            } label: {
                Text("Turn off sharing")
            }
        } footer: {
            Text("Turning it off leaves the foods on both phones, and leaves the food list on Nightscout as it is.")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch service.status {
        case .off:
            Text("Off")
        case .syncing:
            Text("Syncing…")
        case let .idle(lastSync):
            if let lastSync {
                Text(lastSync, format: .dateTime.hour().minute())
            } else {
                Text("Not synced yet")
            }
        case let .failed(message):
            Text(message)
                .foregroundColor(.red)
        }
    }

    private func enable() {
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }

        isWorking = true
        errorMessage = nil

        Task {
            do {
                try await service.enableSync(apiSecret: secret)
                apiSecret = ""
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
