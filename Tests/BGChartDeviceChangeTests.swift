// LoopFollow
// BGChartDeviceChangeTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Which pump and sensor changes the chart marks.
struct BGChartDeviceChangeTests {
    private static let now = Date(timeIntervalSince1970: 1_795_385_820)

    private static func hours(_ value: Double) -> Date {
        now.addingTimeInterval(value * 3600)
    }

    @Test("pump and sensor changes are listed oldest first")
    func oldestFirst() {
        let changes = BGChartModel.DeviceChange.list(pump: [Self.hours(-2)], sensor: [Self.hours(-5)])
        #expect(changes.map(\.kind) == [.sensor, .pump])
        #expect(changes.map(\.date) == [Self.hours(-5), Self.hours(-2)])
    }

    @Test("a change that is in Nightscout twice is marked once")
    func duplicates() {
        let changes = BGChartModel.DeviceChange.list(pump: [Self.hours(-2), Self.hours(-2).addingTimeInterval(4 * 60)], sensor: [])
        #expect(changes.count == 1)
        #expect(changes.first?.date == Self.hours(-2))
    }

    @Test("two pump changes the same day are both marked")
    func twoChanges() {
        #expect(BGChartModel.DeviceChange.list(pump: [Self.hours(-9), Self.hours(-1)], sensor: []).count == 2)
    }

    @Test("pump and sensor changed together are both marked, at different heights")
    func together() {
        let changes = BGChartModel.DeviceChange.list(pump: [Self.hours(-2)], sensor: [Self.hours(-2).addingTimeInterval(60)])
        #expect(changes.count == 2)
        #expect(changes[0].labelFraction != changes[1].labelFraction)
        #expect(changes[0].id != changes[1].id)
    }

    @Test("pump and sensor changes have the tiles' icons")
    func icons() {
        let changes = BGChartModel.DeviceChange.list(pump: [Self.hours(-2)], sensor: [Self.hours(-5)])
        #expect(changes.map(\.symbolName) == ["sensor.tag.radiowaves.forward.fill", "cross.vial.fill"])
    }
}
