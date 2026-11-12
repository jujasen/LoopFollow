// LoopFollow
// EveningWatchAlarmEditor.swift

import SwiftUI

/// The alarm for Loop's evening watch, and Loop's own settings for it to read.
struct EveningWatchAlarmEditor: View {
    @Binding var alarm: Alarm
    @ObservedObject private var loopSettings = Storage.shared.eveningWatchLoopSettings

    var body: some View {
        Group {
            InfoBanner(text: EveningWatchText.explanation, alarmType: alarm.type)

            AlarmGeneralSection(alarm: $alarm)

            Section(
                header: Text(String(localized: "In Loop", table: "EveningWatch", comment: "Section header: the evening watch's settings in Loop")),
                footer: Text(EveningWatchText.declineReachesLoop)
            ) {
                if let settings = loopSettings.value {
                    row(String(localized: "Mode", table: "EveningWatch", comment: "Evening watch setting"), EveningWatchText.mode(settings.mode))
                    if let start = settings.start, let end = settings.end {
                        row(String(localized: "Evening", table: "EveningWatch", comment: "Evening watch setting: the window"), "\(EveningWatchText.clock(start))–\(EveningWatchText.clock(end))")
                    }
                    if let rising = settings.risingFromMmol, let high = settings.highFromMmol {
                        row(String(localized: "Rising from / high from", table: "EveningWatch", comment: "Evening watch setting: the two glucose limits"), "\(EveningWatchText.mmol(rising)) / \(EveningWatchText.mmol(high))")
                    }
                    if let late = settings.lateFrom {
                        row(String(localized: "Late from", table: "EveningWatch", comment: "Evening watch setting"), EveningWatchText.clock(late))
                    }
                    if let units = settings.learnedUnits ?? settings.startUnits {
                        row(String(localized: "Dose at 12", table: "EveningWatch", comment: "Evening watch setting: the dose at 12 mmol/L"), EveningWatchText.unitsWithUnit(units))
                    }
                    if let perEvening = settings.maximumPerEvening, let doses = settings.dosesPerEvening {
                        row(String(localized: "At most per evening", table: "EveningWatch", comment: "Evening watch setting"), "\(EveningWatchText.unitsWithUnit(perEvening)) · \(doses)×")
                    }
                    if let iob = settings.maximumIOB {
                        row(String(localized: "Insulin on board under", table: "EveningWatch", comment: "Evening watch setting"), EveningWatchText.unitsWithUnit(iob))
                    }
                } else {
                    Text(EveningWatchText.notUploaded)
                        .foregroundColor(.secondary)
                }
                NavigationLink(String(localized: "What it has done", table: "EveningWatch", comment: "Opens the evening watch's log")) {
                    EveningWatchLogView()
                }
            }

            Section(
                header: Text(String(localized: "Notification", table: "EveningWatch", comment: "Section header: how the evening watch notifies")),
                footer: Text(EveningWatchText.plainNotification)
            ) {
                AlarmEnumMenuPicker(
                    title: String(localized: "Sound", table: "EveningWatch", comment: "Evening watch setting: when the notification makes a sound"),
                    selection: $alarm.playSoundOption,
                    allowed: PlaySoundOption.allowed(for: alarm.activeOption)
                )
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
