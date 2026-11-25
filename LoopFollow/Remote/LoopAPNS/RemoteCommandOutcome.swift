// LoopFollow
// RemoteCommandOutcome.swift

import SwiftUI

/// A short, plain outcome for a sent command — «Given at 12:04», «Rejected: …» —
/// with a symbol and colour, for Home's one-line status and the list of recent
/// commands under Remote. The long explanations stay in `RemoteCommandText`.
enum RemoteCommandOutcome {
    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func text(_ command: QueuedRemoteCommand, now: Date) -> String {
        let message = (command.statusMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch command.phase(now: now) {
        case .waiting:
            return String(localized: "Waiting for Loop", table: "RemoteControl")
        case .giving:
            return String(localized: "Loop is giving it now", table: "RemoteControl")
        case .given:
            let at = time(command.seenInNightscout ?? command.handledAt ?? command.sentAt)
            if command.isBolus {
                return String(format: String(localized: "Given at %@", table: "RemoteControl", comment: "1: time"), at)
            }
            return String(format: String(localized: "Done at %@", table: "RemoteControl", comment: "A command that is not a bolus was carried out; 1: time"), at)
        case .failed:
            let base = command.isBolus
                ? String(localized: "Not given", table: "RemoteControl")
                : String(localized: "Failed", table: "RemoteControl", comment: "A command that is not a bolus could not be carried out")
            return message.isEmpty ? base : base + ": " + message
        case .rejected:
            if message.isEmpty {
                return String(localized: "Rejected by Loop", table: "RemoteControl")
            }
            return String(format: String(localized: "Rejected: %@", table: "RemoteControl", comment: "1: Loop's reason"), message)
        case .stopped:
            return String(localized: "Stopped: someone else had just given a dose", table: "RemoteControl")
        case .uncertain:
            return String(localized: "Unsure whether it was given", table: "RemoteControl")
        case .cancelled:
            return String(localized: "Withdrawn", table: "RemoteControl")
        case .lapsed:
            return String(localized: "Never reached Loop", table: "RemoteControl")
        case .noAnswer:
            return String(localized: "Loop started but has not answered", table: "RemoteControl")
        case .pushWaiting:
            return String(localized: "Sent as a push", table: "RemoteControl")
        case .pushLapsed:
            return String(localized: "No bolus in Nightscout", table: "RemoteControl")
        }
    }

    static func symbol(_ phase: QueuedRemoteCommand.Phase) -> String {
        switch phase {
        case .waiting, .pushWaiting: return "hourglass.circle"
        case .giving: return "arrow.triangle.2.circlepath.circle"
        case .given: return "checkmark.circle"
        case .failed, .rejected: return "xmark.circle"
        case .stopped: return "hand.raised.circle"
        case .uncertain, .noAnswer, .pushLapsed: return "exclamationmark.triangle"
        case .cancelled: return "arrow.uturn.backward.circle"
        case .lapsed: return "clock.badge.xmark"
        }
    }

    static func tint(_ phase: QueuedRemoteCommand.Phase) -> Color {
        switch phase {
        case .given: return HomePalette.carbs
        case .waiting, .giving, .pushWaiting: return HomePalette.basal
        case .uncertain, .noAnswer, .pushLapsed, .lapsed: return HomePalette.warning
        case .stopped, .failed, .rejected: return .red
        case .cancelled: return .secondary
        }
    }

    /// Outcomes where the longer explanation matters before anyone sends again.
    static func needsAttention(_ phase: QueuedRemoteCommand.Phase) -> Bool {
        switch phase {
        case .uncertain, .noAnswer, .stopped, .pushLapsed, .lapsed:
            return true
        default:
            return false
        }
    }
}

/// One sent command: what it was, what became of it and when it was sent.
/// Tap to read Loop's full answer.
struct RemoteCommandOutcomeRow: View {
    let command: QueuedRemoteCommand
    let now: Date
    /// Show the time it was sent on the right (the history list), or the controls (Home).
    var showsSentTime: Bool = true
    @State private var expanded = false

    var body: some View {
        let phase = command.phase(now: now)
        let showsDetail = expanded || (!showsSentTime && RemoteCommandOutcome.needsAttention(phase))
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: RemoteCommandOutcome.symbol(phase))
                .font(.title3)
                .foregroundStyle(RemoteCommandOutcome.tint(phase))
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                let outcomeColor = phase == .given ? Color.secondary : RemoteCommandOutcome.tint(phase)
                if showsSentTime {
                    Text(command.summary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(RemoteCommandOutcome.text(command, now: now))
                        .font(.footnote)
                        .foregroundStyle(outcomeColor)
                        .lineLimit(showsDetail ? nil : 1)
                } else {
                    // Home: one line, «Bolus 3,2 E · Given at 13:59».
                    (Text(command.summary).fontWeight(.semibold)
                        + Text(" · " + RemoteCommandOutcome.text(command, now: now)).foregroundColor(outcomeColor))
                        .font(.subheadline)
                        .lineLimit(showsDetail ? nil : 1)
                        .minimumScaleFactor(0.85)
                }
                if showsDetail {
                    Text(RemoteCommandText.detail(command, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            if showsSentTime {
                Text(command.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                controls(phase)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func controls(_ phase: QueuedRemoteCommand.Phase) -> some View {
        switch phase {
        case .waiting:
            Button(String(localized: "Withdraw", table: "RemoteCommandInbox")) {
                RemoteCommandInbox.shared.cancel(command)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .giving:
            ProgressView()
        default:
            Button {
                RemoteCommandInbox.shared.dismiss(command)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Hide", table: "RemoteCommandInbox"))
        }
    }
}
