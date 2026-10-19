// LoopFollow
// PumpFailureAlarmEditor.swift

import SwiftUI

struct PumpFailureAlarmEditor: View {
    @Binding var alarm: Alarm

    var body: some View {
        Group {
            InfoBanner(
                text: String(localized: "Alerts when glucose stays high and is not falling although the insulin given should have brought it down — the pod may not be delivering, for example a kinked cannula or a leak the pod does not alarm for. Insulin and carbs over the last 90 minutes are weighed with the profile's ISF and carb ratio.", table: "PumpFailure", comment: "Explanation at the top of the pump-delivery alert settings"),
                alarmType: alarm.type
            )

            AlarmGeneralSection(alarm: $alarm)

            AlarmBGSection(
                header: String(localized: "High Glucose Limit", table: "PumpFailure", comment: "Section header"),
                footer: String(localized: "Only alert at or above this glucose.", table: "PumpFailure", comment: "Section footer"),
                title: String(localized: "BG", table: "PumpFailure", comment: "Picker title"),
                range: 180 ... 400,
                value: $alarm.aboveBG
            )

            AlarmBGSection(
                header: String(localized: "Unexplained Rise", table: "PumpFailure", comment: "Section header"),
                footer: String(localized: "How much higher glucose must be after 90 minutes than the insulin and carbs given explain.", table: "PumpFailure", comment: "Section footer"),
                title: String(localized: "At least", table: "PumpFailure", comment: "Picker title"),
                range: 36 ... 270,
                value: $alarm.delta
            )

            AlarmBGSection(
                header: String(localized: "Insulin Given", table: "PumpFailure", comment: "Section header"),
                footer: String(localized: "How far the insulin acting over the last 90 minutes should have lowered glucose. Keeps the alert quiet when too little insulin was given for its absence to show.", table: "PumpFailure", comment: "Section footer"),
                title: String(localized: "Should lower by", table: "PumpFailure", comment: "Picker title"),
                range: 36 ... 360,
                value: $alarm.threshold
            )

            AlarmStepperSection(
                header: String(localized: "Persistent", table: "PumpFailure", comment: "Section header"),
                footer: String(localized: "Every reading over this long must meet the limits above.", table: "PumpFailure", comment: "Section footer"),
                title: String(localized: "For", table: "PumpFailure", comment: "Stepper title"),
                range: 10 ... 90,
                step: 5,
                unitLabel: "min",
                value: $alarm.persistentMinutes
            )

            AlarmActiveSection(alarm: $alarm)
            AlarmAudioSection(alarm: $alarm)
            AlarmSnoozeSection(alarm: $alarm)
        }
    }
}
