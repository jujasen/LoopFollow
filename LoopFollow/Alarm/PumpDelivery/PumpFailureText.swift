// LoopFollow
// PumpFailureText.swift

import Foundation

/// The pump-delivery alert's notification, in its own table (PumpFailure.xcstrings).
enum PumpFailureText {
    static var title: String {
        String(localized: "Pump may not be delivering insulin", table: "PumpFailure", comment: "Title of the alert when glucose keeps rising although insulin was given")
    }

    static var acknowledgeTitle: String {
        String(localized: "I've checked", table: "PumpFailure", comment: "Button on the pump-delivery alert: silences it until glucose comes down or the pod is changed")
    }

    static var snoozeHourTitle: String {
        String(localized: "Snooze 1 h", table: "PumpFailure", comment: "Button on the pump-delivery alert: snoozes it for one hour")
    }

    static var acknowledgeHint: String {
        String(localized: "«I've checked» keeps it quiet until glucose comes down or the pod is changed.", table: "PumpFailure", comment: "Explains the acknowledge button on the pump-delivery alert")
    }

    static func body(_ assessment: PumpDeliveryCheck.Assessment?) -> String {
        let advice = String(localized: "Check the pod and cannula, measure ketones, and consider insulin by pen and a new pod.", table: "PumpFailure", comment: "Advice in the pump-delivery alert")
        guard let assessment else { return advice }
        let unit = UnitSettingsStore.shared.glucoseUnit.rawValue
        func glucose(_ value: Double) -> String { "\(Localizer.formatQuantity(value)) \(unit)" }
        let finding = String(
            format: String(localized: "Glucose %1$@ and not falling. The insulin from the last 90 minutes should have lowered it by %2$@, yet it is %3$@ higher than insulin and carbs explain.", table: "PumpFailure", comment: "Pump-delivery alert: current glucose, expected drop from insulin, unexplained rise"),
            glucose(assessment.glucose),
            glucose(assessment.insulinDrop),
            glucose(assessment.unexplainedRise)
        )
        return finding + " " + advice
    }
}
