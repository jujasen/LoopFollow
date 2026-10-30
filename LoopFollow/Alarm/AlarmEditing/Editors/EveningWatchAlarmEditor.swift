// LoopFollow
// EveningWatchAlarmEditor.swift

import SwiftUI

struct EveningWatchAlarmEditor: View {
    @Binding var alarm: Alarm
    @ObservedObject private var state = Storage.shared.eveningWatchState

    var body: some View {
        Group {
            InfoBanner(text: EveningWatchText.explanation, alarmType: alarm.type)

            AlarmGeneralSection(alarm: $alarm)

            Section(
                header: Text(String(localized: "Evening", table: "EveningWatch", comment: "Section header: the evening watch's window")),
                footer: Text(String(localized: "Only between these times; the end may be after midnight.", table: "EveningWatch", comment: "Section footer"))
            ) {
                DatePicker(String(localized: "From", table: "EveningWatch", comment: "Start of the evening watch's window"), selection: time($alarm.eveningStartMinutes, default: EveningWatch.Settings().start), displayedComponents: .hourAndMinute)
                DatePicker(String(localized: "To", table: "EveningWatch", comment: "End of the evening watch's window"), selection: time($alarm.eveningEndMinutes, default: EveningWatch.Settings().end), displayedComponents: .hourAndMinute)
            }

            AlarmBGSection(
                header: String(localized: "High Glucose Limit", table: "EveningWatch", comment: "Section header"),
                footer: String(localized: "Suggests at or above this.", table: "EveningWatch", comment: "Section footer"),
                title: String(localized: "BG", table: "EveningWatch", comment: "Picker title"),
                range: 162 ... 300,
                value: $alarm.aboveBG
            )

            AlarmStepperSection(
                header: String(localized: "Persistent", table: "EveningWatch", comment: "Section header"),
                footer: String(localized: "Every reading over this long must be at most 1 mmol/L under the limit, without falling.", table: "EveningWatch", comment: "Section footer"),
                title: String(localized: "For", table: "EveningWatch", comment: "Stepper title"),
                range: 15 ... 90,
                step: 5,
                unitLabel: "min",
                value: $alarm.persistentMinutes
            )

            AlarmStepperSection(
                header: String(localized: "Insulin on Board", table: "EveningWatch", comment: "Section header"),
                footer: String(localized: "No suggestion with this much insulin on board or more.", table: "EveningWatch", comment: "Section footer"),
                title: String(localized: "Under", table: "EveningWatch", comment: "Stepper title"),
                range: 0.5 ... 3,
                step: 0.1,
                unitLabel: String(localized: "U"),
                value: $alarm.threshold
            )

            AlarmStepperSection(
                header: String(localized: "Start Dose", table: "EveningWatch", comment: "Section header"),
                footer: EveningWatchText.doseFooter,
                title: String(localized: "Dose", table: "EveningWatch", comment: "Stepper title"),
                range: 0.1 ... 1,
                step: 0.05,
                unitLabel: String(localized: "U"),
                value: $alarm.eveningStartUnits
            )

            Section(footer: Text(EveningWatchText.rules(settings: EveningWatch.Settings(alarm: alarm)))) {
                HStack {
                    Text(String(localized: "Learned dose", table: "EveningWatch", comment: "The dose the evening watch has learned"))
                    Spacer()
                    if let learned = state.value.learnedUnits {
                        Text("\(EveningWatchText.units(learned)) \(String(localized: "U"))")
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(localized: "Not yet", table: "EveningWatch", comment: "Nothing learned yet"))
                            .foregroundColor(.secondary)
                    }
                }
                if state.value.learnedUnits != nil {
                    Button(String(localized: "Start over from the start dose", table: "EveningWatch", comment: "Forgets the learned dose")) {
                        state.value.learnedUnits = nil
                    }
                }
                NavigationLink(String(localized: "What it has done", table: "EveningWatch", comment: "Opens the evening watch's log")) {
                    EveningWatchLogView()
                }
            }

            AlarmAudioSection(alarm: $alarm)
        }
    }

    /// A time of day for minutes after midnight.
    private func time(_ minutes: Binding<Int?>, default fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let value = minutes.wrappedValue ?? fallback
                return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                minutes.wrappedValue = EveningWatch.minutes(date)
            }
        )
    }
}
