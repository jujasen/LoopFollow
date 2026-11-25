// LoopFollow
// LoopAPNSRemoteView.swift

import SwiftUI

/// Remote control for Loop, as an ordinary iOS list: whether Loop responds, the
/// commands, the lists and settings, and what became of the latest commands.
struct LoopAPNSRemoteView: View {
    @StateObject private var viewModel = RemoteSettingsViewModel()
    @ObservedObject private var activeOverrideNote = Observable.shared.override
    @ObservedObject private var overrideEndAt = Observable.shared.overrideEndAt
    @ObservedObject private var lastLoopTime = Observable.shared.alertLastLoopTime
    @ObservedObject private var loopStatusText = Observable.shared.loopStatusText
    @ObservedObject private var loopRemoteCommands = Storage.shared.loopRemoteCommands
    @ObservedObject private var inbox = RemoteCommandInbox.shared

    /// How many of the latest commands the list shows.
    private static let recentCount = 8

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.loopAPNSSetup {
                    commandList
                } else {
                    notConfigured
                }
            }
            .navigationTitle(String(localized: "Remote", table: "RemoteControl", comment: "Title of the remote control screen"))
            .navigationBarTitleDisplayMode(viewModel.loopAPNSSetup ? .large : .inline)
        }
    }

    // MARK: Configured

    private var commandList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    loopStatusRow(now: context.date)
                }

                Section {
                    NavigationLink(destination: LoopAPNSCarbsView()) {
                        RemoteHubRow(
                            systemImage: "fork.knife",
                            tint: .green,
                            title: String(localized: "Meal", table: "RemoteControl"),
                            subtitle: String(localized: "Carbs and bolus in one command", table: "RemoteControl")
                        )
                    }
                    NavigationLink(destination: LoopAPNSBolusView()) {
                        RemoteHubRow(
                            systemImage: "drop.fill",
                            tint: .orange,
                            title: String(localized: "Bolus", table: "RemoteControl"),
                            subtitle: String(localized: "Correction without carbs", table: "RemoteControl")
                        )
                    }
                    NavigationLink(destination: OverridePresetsView()) {
                        RemoteHubRow(
                            systemImage: "slider.horizontal.3",
                            tint: .blue,
                            title: String(localized: "Override", table: "RemoteControl"),
                            subtitle: OverrideStatusText.subtitle(name: activeOverrideNote.value, endAt: overrideEndAt.value, now: context.date),
                            subtitleTint: activeOverrideNote.value != nil ? HomePalette.basal : nil
                        )
                    }
                }

                Section {
                    NavigationLink(destination: LoggedMealsView()) {
                        RemoteHubRow(
                            systemImage: "pencil",
                            tint: .gray,
                            title: String(localized: "Logged Meals", table: "CarbEdit", comment: "Remote control button that opens the logged meals list"),
                            subtitle: String(localized: "Change or delete carbs", table: "RemoteControl")
                        )
                    }
                    NavigationLink(destination: TherapySettingsView()) {
                        RemoteHubRow(
                            systemImage: "list.bullet.clipboard",
                            tint: .gray,
                            title: String(localized: "Therapy Settings", table: "RemoteControl"),
                            subtitle: String(localized: "Basal, carb ratio, sensitivity, target", table: "RemoteControl")
                        )
                    }
                    // Walter's Loop has no profile patch, so the row only appears for a Loop that reports it.
                    if loopRemoteCommands.value.contains(LoopProfile.switchCommand) {
                        NavigationLink(destination: LoopProfilesView()) {
                            RemoteHubRow(
                                systemImage: "arrow.triangle.2.circlepath",
                                tint: .gray,
                                title: String(localized: "Profiles", table: "RemoteControl"),
                                subtitle: String(localized: "Switch Loop's saved profile", table: "RemoteControl")
                            )
                        }
                    }
                }

                Section {
                    let recent = recentCommands(now: context.date)
                    if recent.isEmpty {
                        Text(String(localized: "No commands in the last 24 hours", table: "RemoteControl"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recent) { command in
                            RemoteCommandOutcomeRow(command: command, now: context.date)
                                .swipeActions(edge: .trailing) {
                                    if command.phase(now: context.date) == .waiting {
                                        Button(String(localized: "Withdraw", table: "RemoteCommandInbox")) {
                                            RemoteCommandInbox.shared.cancel(command)
                                        }
                                        .tint(.orange)
                                    }
                                }
                        }
                    }
                } header: {
                    Text(String(localized: "Recent Commands", table: "RemoteControl"))
                } footer: {
                    Text(String(localized: "Tap a command for Loop's full answer. The one-time code is added automatically and never shown.", table: "RemoteControl"))
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func recentCommands(now: Date) -> [QueuedRemoteCommand] {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        return Array(
            inbox.commands
                .filter { $0.sentAt >= cutoff }
                .sorted { $0.sentAt > $1.sentAt }
                .prefix(Self.recentCount)
        )
    }

    private func loopStatusRow(now: Date) -> some View {
        let raw = lastLoopTime.value ?? 0
        let lastLoop = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        let freshness = LoopFreshness(lastLoop: lastLoop, now: now)
        return HStack(spacing: 12) {
            LoopRingView(freshness: freshness, isOpenLoop: loopStatusText.value == "⏀", lineWidth: 5)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(LoopResponseStatus.title(freshness))
                    .font(.body.weight(.semibold))
                Text(LoopResponseStatus.detail(lastLoop: lastLoop, now: now, viaNightscout: inbox.isAvailable))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Not configured

    private var notConfigured: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 80))
                .foregroundColor(.orange)

            VStack(spacing: 16) {
                Text("Loop APNS Not Configured")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Please configure Loop APNS settings in Remote Settings to use APNS commands.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 32)
            }

            NavigationLink(destination: RemoteSettingsView(viewModel: viewModel)) {
                HStack(spacing: 12) {
                    Image(systemName: "gear")
                        .font(.system(size: 18))
                    Text("Configure Loop APNS")
                        .font(.headline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

/// A row in the remote control list: a tinted icon square, a title and a subtitle.
struct RemoteHubRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    var subtitleTint: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            TintedIconSquare(systemName: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.footnote.weight(subtitleTint == nil ? .regular : .medium))
                    .foregroundStyle(subtitleTint ?? .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
