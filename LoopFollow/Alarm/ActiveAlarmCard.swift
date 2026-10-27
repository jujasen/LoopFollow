// LoopFollow
// ActiveAlarmCard.swift

import SwiftUI

/// The sounding alarm, shown above every tab except the Snoozer, so it can be
/// silenced wherever the app is — also when the Snoozer tab sits in the menu.
struct ActiveAlarmCard: View {
    let alarm: Alarm
    @ObservedObject private var assessment = Observable.shared.pumpFailureAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: alarm.type.icon)
                    .font(.title2)
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(alarm.type == .pumpFailure ? PumpFailureText.title : alarm.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if alarm.type == .pumpFailure {
                        Text(PumpFailureText.body(assessment.value))
                            .font(.footnote)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if alarm.type == .pumpFailure {
                PumpFailureAlarmButtons(compact: true)
            } else {
                Button {
                    AlarmManager.shared.performSnooze()
                } label: {
                    Text(alarm.snoozeDuration == 0 ? String(localized: "Acknowledge") : String(localized: "Snooze"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// «Jeg har sjekket» and «Slumre 1 t» for the pump-delivery alert.
struct PumpFailureAlarmButtons: View {
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            HStack(spacing: 12) {
                Button {
                    AlarmManager.shared.acknowledgePumpFailure()
                } label: {
                    Text(PumpFailureText.acknowledgeTitle)
                        .font(compact ? .headline : .title2.bold())
                        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    AlarmManager.shared.snoozePumpFailure()
                } label: {
                    Text(PumpFailureText.snoozeHourTitle)
                        .font(compact ? .headline : .title2.bold())
                        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 60)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            Text(PumpFailureText.acknowledgeHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
