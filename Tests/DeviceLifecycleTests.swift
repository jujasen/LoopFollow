// LoopFollow
// DeviceLifecycleTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct DeviceLifecycleTests {
    private let start = Date(timeIntervalSince1970: 1_791_000_000)
    private func at(hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }

    @Test("G7 walks through warmup, lifetime, grace and expiry")
    func g7Phases() {
        let sensor = SensorKind.dexcomG7.lifecycle(startingAt: start)
        #expect(sensor.phase(at: at(hours: 0.2)) == .warmup)
        #expect(sensor.phase(at: at(hours: 1)) == .active)
        #expect(sensor.phase(at: at(hours: 240.5)) == .grace)
        #expect(sensor.phase(at: at(hours: 252.5)) == .expired)
        #expect(sensor.expiration == at(hours: 240))
        #expect(sensor.graceEnd == at(hours: 252))
        #expect(sensor.remaining(at: at(hours: 252.5)) == nil)
    }

    @Test("pod expires at 72 h and stops at 80 h")
    func podPhases() {
        let pod = PumpKind.omnipod.lifecycle(startingAt: start)
        #expect(pod.phase(at: start) == .active)
        #expect(abs((pod.remaining(at: at(hours: 42)) ?? 0) - 30 * 3600) < 1)
        #expect(abs(pod.progress(at: at(hours: 36)) - 0.5) < 0.001)
        #expect(pod.phase(at: at(hours: 75)) == .grace)
        #expect(abs((pod.remaining(at: at(hours: 75)) ?? 0) - 5 * 3600) < 1)
        #expect(pod.phase(at: at(hours: 80)) == .expired)
    }

    @Test("bar turns warning in the last 24 hours and critical after expiry")
    func levels() {
        let pod = PumpKind.omnipod.lifecycle(startingAt: start)
        #expect(pod.level(at: at(hours: 47)) == .normal)
        #expect(pod.level(at: at(hours: 48)) == .warning)
        #expect(pod.level(at: at(hours: 73)) == .critical)
    }

    @Test("sensor kind comes from the entries' device, else the sensor ID")
    func sensorKind() {
        #expect(SensorKind.detect(deviceName: "Dexcom G7 DXCMKW", sensorID: nil) == .dexcomG7)
        #expect(SensorKind.detect(deviceName: "com.dexcom.g7app", sensorID: nil) == .dexcomG7)
        #expect(SensorKind.detect(deviceName: "share2", sensorID: "DXCMKW") == .dexcomG7)
        #expect(SensorKind.detect(deviceName: "Dexcom G6", sensorID: nil) == .dexcomG6)
        #expect(SensorKind.detect(deviceName: "xDrip-LibreReceiver", sensorID: nil) == .libre)
        #expect(SensorKind.detect(deviceName: nil, sensorID: nil) == .other)
    }

    @Test("sensor ID is read from Loop's Sensor Start note")
    func sensorID() {
        #expect(SensorKind.sensorID(fromNotes: "SensorID: DXCMKW") == "DXCMKW")
        #expect(SensorKind.sensorID(fromNotes: "SensorID:") == nil)
        #expect(SensorKind.sensorID(fromNotes: "Pod Change") == nil)
        #expect(SensorKind.sensorID(fromNotes: nil) == nil)
    }

    @Test("pump kind recognizes Omnipod models")
    func pumpKind() {
        #expect(PumpKind.detect(model: "Omnipod DASH") == .omnipod)
        #expect(PumpKind.detect(model: "Dash") == .omnipod)
        #expect(PumpKind.detect(model: "Eros") == .omnipod)
        #expect(PumpKind.detect(model: "723") == .other)
    }

    @Test("remaining time splits like Loop's pod screen")
    func components() {
        let long = DeviceStatusFormat.components(30 * 3600 + 15 * 60).map(\.value)
        #expect(long == [1, 6])
        let short = DeviceStatusFormat.components(90 * 60).map(\.value)
        #expect(short == [1, 30])
        let minutes = DeviceStatusFormat.components(20 * 60).map(\.value)
        #expect(minutes == [20])
    }
}
