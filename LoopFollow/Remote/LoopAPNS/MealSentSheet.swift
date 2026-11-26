// LoopFollow
// MealSentSheet.swift

// Step 3: what has become of a meal with bolus, step by step, from what Loop writes back into the
// command in Nightscout. Only what LoopFollow knows is shown; there is no made-up progress.

import SwiftUI

struct MealSentSheet: View {
    let commandId: String
    let onClose: () -> Void

    @ObservedObject private var inbox = RemoteCommandInbox.shared

    var body: some View {
        NavigationView {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if let command = inbox.commands.first(where: { $0.commandId == commandId }) {
                    content(command, now: context.date)
                } else {
                    Text("Remote command", tableName: "RemoteCommandInbox")
                }
            }
            .navigationTitle(Text("Sent to Loop", tableName: "MealBolus"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { inbox.fetchNow() }
    }

    @ViewBuilder
    private func content(_ command: QueuedRemoteCommand, now: Date) -> some View {
        let steps = MealSentSteps.steps(for: command, now: now)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RemoteCommandText.title(command, now: now))
                        .font(.title3.weight(.semibold))
                    if let meal = command.meal {
                        Text(MealSentSteps.headline(meal))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let recommended = meal.recommendedUnits {
                            Text(String(format: String(localized: "You approved up to %@. Loop worked out %@.", table: "MealBolus", comment: "1: approved units, 2: Loop's recommendation"), RemoteDoseContext.units(meal.approvedUnits), RemoteDoseContext.units(recommended)))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(steps) { step in
                    MealSentStepRow(step: step)
                }
            } footer: {
                // The steps and the headline already say this while it goes well.
                switch command.phase(now: now) {
                case .waiting, .giving, .given:
                    EmptyView()
                default:
                    Text(RemoteCommandText.detail(command, now: now))
                }
            }

            Section {
                GiveAnywayButton(command: command, now: now)
                if command.phase(now: now) == .waiting {
                    Button(role: .destructive) {
                        inbox.cancel(command)
                    } label: {
                        Text("Withdraw", tableName: "RemoteCommandInbox")
                    }
                }
            } footer: {
                Text("You can close this. The status is shown on Home, and you get a notification when the bolus is given or if Loop rejects it.", tableName: "MealBolus")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onClose) {
                Text("Close", tableName: "MealBolus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// One line in the sheet: Sent → Loop received it → Carbs saved → Bolus given.
struct MealSentStep: Identifiable, Equatable {
    enum State: Equatable {
        case done
        /// What is going on now; a spinner, not a progress bar.
        case current
        case pending
        case failed
        case warning
        /// Done, but nothing was needed (no bolus).
        case skipped
    }

    let id: Int
    let title: String
    let detail: String?
    let state: State
}

enum MealSentSteps {
    /// «🍕 Pizza 45 g + inntil 3,25 E»
    static func headline(_ meal: MealBolusDetails) -> String {
        let food = meal.foodType.map { $0 + " " } ?? ""
        return String(format: String(localized: "%@%@ g + up to %@", table: "MealBolus", comment: "1: food name with a trailing space or nothing, 2: grams, 3: units"), food, RemoteCommandText.grams(meal.carbs), RemoteDoseContext.units(meal.approvedUnits))
    }

    private static func seconds(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func steps(for command: QueuedRemoteCommand, now: Date) -> [MealSentStep] {
        let phase = command.phase(now: now)
        let meal = command.meal

        // 1. In Nightscout.
        let sent = MealSentStep(
            id: 0,
            title: String(localized: "Sent", table: "MealBolus"),
            detail: String(format: String(localized: "%@ · put in Nightscout", table: "MealBolus", comment: "1: time"), seconds(command.sentAt)),
            state: .done
        )

        // 2. Loop has it.
        let received: MealSentStep
        let receivedAt = command.receivedAt ?? (command.status != .pending && command.status != .cancelled ? command.handledAt : nil)
        if let receivedAt {
            let after = max(0, Int(receivedAt.timeIntervalSince(command.sentAt).rounded()))
            received = MealSentStep(id: 1, title: String(localized: "Loop received the command", table: "MealBolus"), detail: String(format: String(localized: "%@ · after %@ seconds", table: "MealBolus", comment: "1: time, 2: seconds"), seconds(receivedAt), "\(after)"), state: .done)
        } else {
            switch phase {
            case .lapsed:
                received = MealSentStep(id: 1, title: String(localized: "Loop received the command", table: "MealBolus"), detail: String(format: String(localized: "Loop did not fetch it before %@.", table: "MealBolus", comment: "1: time"), RemoteDoseContext.time(command.expiration)), state: .failed)
            case .cancelled:
                received = MealSentStep(id: 1, title: String(localized: "Loop received the command", table: "MealBolus"), detail: String(localized: "Withdrawn before Loop fetched it.", table: "MealBolus"), state: .failed)
            default:
                received = MealSentStep(id: 1, title: String(localized: "Loop received the command", table: "MealBolus"), detail: String(localized: "Loop fetches it on its next run (every 5 min), or at once if the push gets through.", table: "MealBolus"), state: phase == .given ? .done : .current)
            }
        }

        // 3. Carbs.
        let carbsText: String? = meal.map { meal in
            var parts = [String(format: String(localized: "%@ g", table: "MealBolus", comment: "1: grams"), RemoteCommandText.grams(meal.carbs))]
            if let food = meal.foodType { parts.append(food) }
            if let hours = meal.absorptionHours { parts.append(String(format: String(localized: "absorbed over %@", table: "MealBolus", comment: "1: e.g. 4 h"), MealAbsorption.shortText(hours: hours))) }
            return parts.joined(separator: " · ")
        }
        let carbsState: MealSentStep.State
        if command.carbsSaved {
            carbsState = .done
        } else {
            switch phase {
            case .failed, .rejected, .stopped:
                carbsState = .failed
            case .noAnswer, .uncertain:
                carbsState = .warning
            case .giving:
                carbsState = .current
            case .given:
                carbsState = .done
            default:
                carbsState = .pending
            }
        }
        let carbs = MealSentStep(
            id: 2,
            title: carbsState == .failed ? String(localized: "Carbs not saved", table: "MealBolus") : String(localized: "Carbs saved", table: "MealBolus"),
            detail: carbsText,
            state: carbsState
        )

        // 4. Bolus.
        let bolus: MealSentStep
        let title = String(localized: "Bolus given", table: "MealBolus")
        switch phase {
        case .given:
            let units = meal?.deliveredUnits ?? command.units ?? 0
            let at = command.seenInNightscout ?? command.handledAt ?? now
            bolus = MealSentStep(id: 3, title: title, detail: String(format: String(localized: "%@ at %@", table: "MealBolus", comment: "1: units, 2: time"), RemoteDoseContext.units(units), RemoteDoseContext.time(at)), state: .done)
        case .savedWithoutBolus:
            let detail = meal?.recommendedUnits.map { String(format: String(localized: "No bolus: Loop worked out %@ with the meal.", table: "MealBolus", comment: "1: units"), RemoteDoseContext.units($0)) } ?? String(localized: "No bolus.", table: "MealBolus")
            bolus = MealSentStep(id: 3, title: String(localized: "No bolus needed", table: "MealBolus"), detail: detail, state: .skipped)
        case .carbsSavedBolusFailed, .failed, .rejected, .stopped:
            bolus = MealSentStep(id: 3, title: String(localized: "Bolus not given", table: "MealBolus"), detail: command.statusMessage, state: .failed)
        case .uncertain, .noAnswer:
            bolus = MealSentStep(id: 3, title: String(localized: "Bolus may have been given", table: "MealBolus"), detail: command.statusMessage, state: .warning)
        case .giving where command.carbsSaved:
            bolus = MealSentStep(id: 3, title: String(localized: "Giving the bolus", table: "MealBolus"), detail: command.handledAt.map { String(format: String(localized: "Started %@", table: "MealBolus", comment: "1: time"), seconds($0)) }, state: .current)
        default:
            bolus = MealSentStep(id: 3, title: title, detail: nil, state: .pending)
        }

        return [sent, received, carbs, bolus]
    }
}

struct MealSentStepRow: View {
    let step: MealSentStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body.weight(step.state == .pending ? .regular : .semibold))
                    .foregroundColor(step.state == .pending ? .secondary : .primary)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title3)
        case .current:
            ProgressView()
        case .pending:
            Image(systemName: "circle.dashed").foregroundColor(.secondary).font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.title3)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.title3)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundColor(.secondary).font(.title3)
        }
    }
}
