// LoopFollow
// AlarmSelectionView.swift

import SwiftUI

struct AlarmSelectionView: View {
    @ObservedObject private var allAlarms = Storage.shared.alarms
    @State private var selectedAlarmIds: Set<UUID> = []
    @State private var showingCharacterLimitAlert = false

    let exportedAlarmIds: Set<UUID>
    let onConfirm: ([Alarm]) -> Void
    let onCancel: () -> Void

    // QR Code character limits (calibrated for alarm exports)
    private let maxQRCharacters = 2000
    private let maxRecommendedAlarms = 5

    // Computed property for actual character count (used internally)
    private var actualCharacterCount: Int {
        let selectedAlarms = allAlarms.value.filter { selectedAlarmIds.contains($0.id) }
        let testExport = AlarmSettingsExport(
            version: AppVersionManager().version(),
            alarms: selectedAlarms,
            alarmConfiguration: Storage.shared.alarmConfiguration.value
        )

        if let jsonString = testExport.encodeToJSON() {
            return jsonString.count
        }
        return 0
    }

    private var exceedsCharacterLimit: Bool {
        return actualCharacterCount > maxQRCharacters
    }

    var body: some View {
        NavigationView {
            VStack {
                // Character count indicator
                characterCountView

                List {
                    ForEach(allAlarms.value) { alarm in
                        AlarmSelectionRow(
                            alarm: alarm,
                            isSelected: selectedAlarmIds.contains(alarm.id),
                            isExported: exportedAlarmIds.contains(alarm.id),
                            isDisabled: !canSelectAlarm(alarm),
                            onToggle: { toggleAlarm(alarm) }
                        )
                    }
                }
            }
            .navigationTitle("Select Alarms to Export")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    onCancel()
                },
                trailing: Button("Export") {
                    let selectedAlarms = allAlarms.value.filter { selectedAlarmIds.contains($0.id) }
                    onConfirm(selectedAlarms)
                }
                .disabled(selectedAlarmIds.isEmpty)
            )
        }
        .alert("Character Limit Reached", isPresented: $showingCharacterLimitAlert) {
            Button("OK") {}
        } message: {
            Text("Adding this alarm would exceed the QR code character limit. Please remove some alarms first.")
        }
    }

    private var characterCountView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Selected Alarms: \(selectedAlarmIds.count)")
                    .font(.headline)
                Spacer()
                Text("Max \(maxRecommendedAlarms) alarms at a time")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if selectedAlarmIds.count > 0 {
                ProgressView(value: Double(selectedAlarmIds.count), total: Double(maxRecommendedAlarms))
                    .progressViewStyle(LinearProgressViewStyle(tint: progressBarColor))
            }
        }
        .padding()
        .background(Color(.systemGray6))
    }

    private var progressBarColor: Color {
        if exceedsCharacterLimit {
            return .red
        } else if selectedAlarmIds.count >= maxRecommendedAlarms {
            return .blue
        } else {
            return .green
        }
    }

    private func canSelectAlarm(_ alarm: Alarm) -> Bool {
        let testSelection = selectedAlarmIds.union([alarm.id])
        let testAlarms = allAlarms.value.filter { testSelection.contains($0.id) }

        // Block if we're at or over the recommended alarm limit
        if testAlarms.count > maxRecommendedAlarms {
            return false
        }

        // Test actual character count to prevent exceeding QR code limit
        let testExport = AlarmSettingsExport(
            version: AppVersionManager().version(),
            alarms: testAlarms,
            alarmConfiguration: Storage.shared.alarmConfiguration.value
        )

        if let jsonString = testExport.encodeToJSON() {
            return jsonString.count <= maxQRCharacters
        }

        return false
    }

    private func toggleAlarm(_ alarm: Alarm) {
        if selectedAlarmIds.contains(alarm.id) {
            selectedAlarmIds.remove(alarm.id)
        } else {
            if canSelectAlarm(alarm) {
                selectedAlarmIds.insert(alarm.id)
            } else {
                showingCharacterLimitAlert = true
            }
        }
    }
}

struct AlarmSelectionRow: View {
    let alarm: Alarm
    let isSelected: Bool
    let isExported: Bool
    let isDisabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(alarm.name)
                            .font(.headline)
                            .foregroundColor(isDisabled ? .secondary : .primary)

                        if isExported {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }

                    Text(alarmTypeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let aboveBG = alarm.aboveBG {
                        Text("Above: \(String(format: "%.0f", aboveBG))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let belowBG = alarm.belowBG {
                        Text("Below: \(String(format: "%.0f", belowBG))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : (isDisabled ? .secondary : .primary))
                    .font(.title2)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !isSelected)
    }

    private var alarmTypeDescription: String {
        switch alarm.type {
        case .temporary:
            return String(localized: "Temporary Alert")
        case .iob:
            return String(localized: "IOB Alert")
        case .cob:
            return String(localized: "COB Alert")
        case .low:
            return String(localized: "Low BG Alert")
        case .high:
            return String(localized: "High BG Alert")
        case .fastDrop:
            return String(localized: "Fast Drop Alert")
        case .fastRise:
            return String(localized: "Fast Rise Alert")
        case .missedReading:
            return String(localized: "Missed Reading Alert")
        case .notLooping:
            return String(localized: "Not Looping Alert")
        case .missedBolus:
            return String(localized: "Missed Bolus Alert")
        case .futureCarbs:
            return String(localized: "Future Carbs Alert")
        case .sensorChange:
            return String(localized: "Sensor Change Alert")
        case .pumpChange:
            return String(localized: "Pump Change Alert")
        case .pump:
            return String(localized: "Pump Insulin Alert")
        case .pumpBattery:
            return String(localized: "Pump Battery Alert")
        case .battery:
            return String(localized: "Low Battery")
        case .batteryDrop:
            return String(localized: "Battery Drop")
        case .recBolus:
            return String(localized: "Rec. Bolus")
        case .overrideStart:
            return String(localized: "Override Started")
        case .overrideEnd:
            return String(localized: "Override Ended")
        case .tempTargetStart:
            return String(localized: "Temp Target Started")
        case .tempTargetEnd:
            return String(localized: "Temp Target Ended")
        case .buildExpire:
            return String(localized: "Looping app expiration")
        case .dbSize:
            return String(localized: "Nightscout Database Size")
        case .pumpFailure:
            return String(localized: "Pump Delivery Alert")
        }
    }
}

#Preview {
    AlarmSelectionView(
        exportedAlarmIds: [],
        onConfirm: { _ in },
        onCancel: {}
    )
}
