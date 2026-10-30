// LoopFollow
// EveningWatchViews.swift

import SwiftUI

/// The suggestion whose bolus screen is open.
final class EveningWatchReview: ObservableObject {
    static let shared = EveningWatchReview()

    @Published var reviewing: EveningWatch.Suggestion?
}

/// «Se over», «Ikke nå» and «Ferdig for i kveld» for the evening watch.
struct EveningWatchAlarmButtons: View {
    var compact: Bool = false
    @ObservedObject private var remoteType = Storage.shared.remoteType

    private var canReview: Bool {
        remoteType.value == .loopAPNS
    }

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            HStack(spacing: 12) {
                if canReview {
                    Button {
                        AlarmManager.shared.reviewEveningWatch()
                    } label: {
                        label(EveningWatchText.review)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    AlarmManager.shared.declineEveningWatch()
                } label: {
                    label(EveningWatchText.notNow)
                }
                .buttonStyle(.bordered)
            }
            .tint(.indigo)

            Button(EveningWatchText.doneForTonight) {
                AlarmManager.shared.declineEveningWatch(forTonight: true)
            }
            .font(compact ? .subheadline : .headline)
            .tint(.indigo)

            Text(canReview ? EveningWatchText.reviewHint : EveningWatchText.noRemoteHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(compact ? .headline : .title2.bold())
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 60)
    }
}

/// The suggestions of the last two weeks and what the watch found at each reading of the last
/// evenings, newest first.
struct EveningWatchLogView: View {
    @ObservedObject private var state = Storage.shared.eveningWatchState

    var body: some View {
        List {
            Section(String(localized: "Suggestions", table: "EveningWatch", comment: "Evening watch log section")) {
                if state.value.suggestions.isEmpty {
                    Text(String(localized: "No suggestions yet.", table: "EveningWatch", comment: "Evening watch log, empty"))
                        .foregroundColor(.secondary)
                }
                ForEach(state.value.suggestions.reversed()) { suggestion in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(suggestion.date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                            Spacer()
                            Text("\(EveningWatchText.units(suggestion.units)) \(String(localized: "U"))")
                                .bold()
                        }
                        Text("\(EveningWatchText.glucose(suggestion.glucose)) · \(EveningWatchText.state(suggestion))")
                            .font(.footnote)
                        if let outcome = EveningWatchText.outcome(suggestion) {
                            Text(outcome)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            ForEach(evenings, id: \.start) { evening in
                Section(evening.start.formatted(.dateTime.weekday(.wide).day().month())) {
                    ForEach(Array(evening.decisions.enumerated()), id: \.offset) { _, decision in
                        HStack(alignment: .firstTextBaseline) {
                            Text(EveningWatchText.time(decision.date))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            Text(decision.glucose.map { Localizer.formatQuantity($0) } ?? "–")
                                .monospacedDigit()
                                .frame(minWidth: 36, alignment: .trailing)
                            Text(EveningWatchText.decision(decision))
                                .foregroundColor(decision.kind == .suggested ? .indigo : .primary)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(EveningWatchText.name)
    }

    private var evenings: [(start: Date, decisions: [EveningWatch.Decision])] {
        let settings = EveningWatch.Settings.current
        let grouped = Dictionary(grouping: state.value.decisions) { EveningWatch.windowStart(before: $0.date, settings: settings) }
        return grouped
            .map { (start: $0.key, decisions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.start > $1.start }
    }
}
