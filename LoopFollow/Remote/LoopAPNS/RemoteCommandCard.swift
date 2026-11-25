// LoopFollow
// RemoteCommandCard.swift

import SwiftUI

/// The commands sent from here and what became of them, on the main screen:
/// one compact line each in a single card, until Loop has answered.
struct RemoteCommandCard: View {
    @ObservedObject private var inbox = RemoteCommandInbox.shared

    var body: some View {
        // Redrawn every 15 seconds, so «waiting» turns into «never reached Loop» on time.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let commands = Array(inbox.visible(now: context.date).prefix(3))
            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 {
                            Divider().padding(.leading, 36)
                        }
                        RemoteCommandOutcomeRow(command: command, now: context.date, showsSentTime: false)
                    }
                }
                .homeCard(padding: 10)
                .padding(.bottom, 8)
            }
        }
    }

    static func background(_ phase: QueuedRemoteCommand.Phase) -> Color {
        switch phase {
        case .given:
            return Color.green.opacity(0.15)
        case .failed, .rejected, .lapsed, .cancelled, .pushLapsed:
            return Color.secondary.opacity(0.15)
        case .uncertain, .noAnswer:
            return Color.orange.opacity(0.25)
        case .stopped:
            return Color.red.opacity(0.25)
        case .waiting, .giving, .pushWaiting:
            return Color.blue.opacity(0.15)
        }
    }
}

struct RemoteCommandRow: View {
    let command: QueuedRemoteCommand
    var now: Date = .init()

    var body: some View {
        let phase = command.phase(now: now)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RemoteCommandText.title(command, now: now))
                    .font(.subheadline.weight(.semibold))
                Text(RemoteCommandText.detail(command, now: now))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if phase == .waiting {
                Button(String(localized: "Withdraw", table: "RemoteCommandInbox")) {
                    RemoteCommandInbox.shared.cancel(command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if phase == .giving {
                ProgressView()
            } else {
                Button {
                    RemoteCommandInbox.shared.dismiss(command)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Hide", table: "RemoteCommandInbox"))
            }
        }
    }
}
