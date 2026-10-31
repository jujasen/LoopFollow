// LoopFollow
// EveningWatchViews.swift

import SwiftUI

/// «Se over», «Ikke nå» and «Avslå» on the evening watch's alarm. Only the alarm goes quiet; the
/// suggestion stays on the main screen until it is answered.
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
                    AlarmManager.shared.quietEveningWatch()
                } label: {
                    label(EveningWatchText.notNow)
                }
                .buttonStyle(.bordered)
            }
            .tint(.indigo)

            Button(EveningWatchText.decline, role: .destructive) {
                AlarmManager.shared.declineEveningWatch()
            }
            .font(compact ? .subheadline : .headline)

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

/// Tonight's doses and suggestions from Loop, then what it found at each change, newest first.
struct EveningWatchLogView: View {
    @ObservedObject private var log = Storage.shared.eveningWatchLog

    var body: some View {
        List {
            if let log = log.value {
                Section(log.date.formatted(.dateTime.weekday(.wide).day().month())) {
                    if log.actions.isEmpty {
                        Text(String(localized: "Nothing given or suggested yet.", table: "EveningWatch", comment: "Evening watch log, empty evening"))
                            .foregroundColor(.secondary)
                    }
                    ForEach(log.actions.reversed()) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(EveningWatchText.time(action.date)).monospacedDigit()
                                Text(EveningWatchText.unitsWithUnit(action.givenUnits ?? action.units)).bold()
                                Spacer()
                                Text(EveningWatchText.state(action))
                                    .foregroundColor(action.state == "failed" ? .orange : .secondary)
                            }
                            Text(EveningWatchText.describe(action))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section(String(localized: "Each change", table: "EveningWatch", comment: "Evening watch log section: what it found")) {
                    ForEach(Array(log.entries.reversed().enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(EveningWatchText.time(entry.date))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            Text(entry.glucose.map(EveningWatchText.mmol) ?? "–")
                                .monospacedDigit()
                                .frame(minWidth: 36, alignment: .trailing)
                            Text(EveningWatchText.decision(entry))
                                .foregroundColor(entry.kind == "suggested" || entry.kind == "dosed" ? .indigo : .primary)
                        }
                        .font(.footnote)
                    }
                }
            } else {
                Text(String(localized: "No log from Loop yet tonight.", table: "EveningWatch", comment: "Evening watch log, none from Loop"))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(EveningWatchText.name)
    }
}
