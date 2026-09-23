// LoopFollow
// TherapySettingsTests.swift

import Foundation
import HealthKit
@testable import LoopFollow
import Testing

/// The `therapy-settings` block is read by Loop's NightscoutService
/// (`TherapySettingsRemoteNotification` / `TherapySettingsAction`), which is tested against the
/// same shape. Change the two together.
struct TherapySettingsTests {
    private static func entry(_ hour: Double, _ value: Double) -> TherapyScheduleEntry {
        TherapyScheduleEntry(start: Int(hour * 3600), value: value)
    }

    @Test func payloadCarriesOnlyChangedSchedules() throws {
        let payload = TherapySchedule.payload(
            carbRatios: [Self.entry(6, 10), Self.entry(0, 12)],
            sensitivities: nil,
            glucoseUnit: .millimolesPerLiter
        )

        #expect(payload["insulin-sensitivity"] == nil)
        #expect(payload["insulin-sensitivity-unit"] == nil)
        let carbRatio = try #require(payload["carb-ratio"] as? [[String: Any]])
        #expect(carbRatio.map { $0["start"] as? Int } == [0, 21600])
        #expect(carbRatio.map { $0["value"] as? Double } == [12, 10])
    }

    @Test func payloadNamesTheGlucoseUnit() throws {
        let mmol = TherapySchedule.payload(carbRatios: nil, sensitivities: [Self.entry(0, 9.5)], glucoseUnit: .millimolesPerLiter)
        #expect(mmol["insulin-sensitivity-unit"] as? String == "mmol/L")

        let mgdl = TherapySchedule.payload(carbRatios: nil, sensitivities: [Self.entry(0, 170)], glucoseUnit: .milligramsPerDeciliter)
        #expect(mgdl["insulin-sensitivity-unit"] as? String == "mg/dL")

        // It must survive the trip through JSON into the APNs body.
        let data = try JSONSerialization.data(withJSONObject: ["therapy-settings": mmol])
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect((decoded["therapy-settings"]?["insulin-sensitivity"] as? [[String: Any]])?.first?["value"] as? Double == 9.5)
    }

    @Test func scheduleMustStartAtMidnight() {
        #expect(throws: TherapySchedule.ValidationError.mustStartAtMidnight) {
            try TherapySchedule.validate([Self.entry(1, 12)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
    }

    @Test func duplicateTimesAreRejected() {
        #expect(throws: TherapySchedule.ValidationError.duplicateTime(3600)) {
            try TherapySchedule.validate([Self.entry(0, 12), Self.entry(1, 10), Self.entry(1, 11)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
    }

    @Test func valuesOutsideLoopsGuardrailsAreRejected() throws {
        // Loop: carb ratio 2–150 g/U, insulin sensitivity 9.1–500.9 mg/dL/U (≈ 0.6–27.8 mmol/L/U).
        #expect(throws: TherapySchedule.ValidationError.self) {
            try TherapySchedule.validate([Self.entry(0, 151)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        }
        #expect(throws: TherapySchedule.ValidationError.self) {
            try TherapySchedule.validate([Self.entry(0, 0.4)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        }
        try TherapySchedule.validate([Self.entry(0, 150), Self.entry(12, 2)], kind: .carbRatio, glucoseUnit: .millimolesPerLiter)
        try TherapySchedule.validate([Self.entry(0, 27.8), Self.entry(12, 0.6)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
    }

    @Test func roundedRangeNeverAllowsAValueLoopRejects() {
        let range = TherapySchedule.allowedRangeRounded(kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        let lowest = HKQuantity(unit: .millimolesPerLiter, doubleValue: range.lowerBound).doubleValue(for: .milligramsPerDeciliter)
        let highest = HKQuantity(unit: .millimolesPerLiter, doubleValue: range.upperBound).doubleValue(for: .milligramsPerDeciliter)
        #expect(lowest >= 9.1)
        #expect(highest <= 500.9)
    }

    @Test func newEntryGoesAfterTheLastAndKeepsTheValueInEffect() throws {
        let schedule = [Self.entry(0, 12), Self.entry(6, 10)]
        let added = try #require(TherapySchedule.newEntry(after: schedule))
        #expect(added.start == Int(6.5 * 3600))
        #expect(added.value == 10)
    }

    @Test func newEntryWrapsToAFreeEarlierTime() throws {
        let schedule = [Self.entry(0, 12), Self.entry(23.5, 10)]
        let added = try #require(TherapySchedule.newEntry(after: schedule))
        #expect(added.start == 1800)
        #expect(added.value == 12)
    }

    @Test func changeLinesDescribeEditsAdditionsAndRemovals() {
        let old = [Self.entry(0, 12), Self.entry(6, 10), Self.entry(18, 14)]
        let new = [Self.entry(0, 12), Self.entry(6, 9.5), Self.entry(14, 11)]
        #expect(TherapySchedule.changeLines(from: old, to: new, digits: 1).count == 3)
        #expect(TherapySchedule.changeLines(from: old, to: old, digits: 1).isEmpty)
    }

    @Test func unchangedProfileComparesEqualAfterRounding() {
        // A value converted by Loop can arrive with float noise; the editor must not see it as a change.
        let fromProfile = TherapySchedule.rounded([Self.entry(0, 9.499999)], kind: .insulinSensitivity, glucoseUnit: .millimolesPerLiter)
        #expect(fromProfile == [Self.entry(0, 9.5)])
    }
}
