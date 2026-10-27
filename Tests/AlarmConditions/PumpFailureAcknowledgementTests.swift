// LoopFollow
// PumpFailureAcknowledgementTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct PumpFailureAcknowledgementTests {
    private let ackTime = Date(timeIntervalSince1970: 1_800_000_000)
    private var ack: PumpFailureAcknowledgement {
        .init(acknowledgedAt: ackTime, podInsertTime: ackTime.timeIntervalSince1970 - 24 * 3600)
    }

    // MARK: - resolve

    @Test("#resolve — fires when suspected and not acknowledged")
    func firesWithoutAck() {
        let outcome = PumpFailureAcknowledgement.resolve(nil, suspected: true, latestMeetsLimits: true, podInsertTime: nil)
        #expect(outcome == .init(fire: true, acknowledgement: nil))
        #expect(!PumpFailureAcknowledgement.resolve(nil, suspected: false, latestMeetsLimits: nil, podInsertTime: nil).fire)
    }

    @Test("#resolve — stays silent while the condition persists")
    func silentWhileAcknowledged() {
        let outcome = PumpFailureAcknowledgement.resolve(ack, suspected: true, latestMeetsLimits: true, podInsertTime: ack.podInsertTime)
        #expect(outcome == .init(fire: false, acknowledgement: ack))
    }

    @Test("#resolve — a gap or stale data does not re-arm")
    func unknownKeepsAck() {
        let outcome = PumpFailureAcknowledgement.resolve(ack, suspected: false, latestMeetsLimits: nil, podInsertTime: ack.podInsertTime)
        #expect(outcome == .init(fire: false, acknowledgement: ack))
    }

    @Test("#resolve — re-arms once the latest reading no longer meets the limits")
    func rearmsWhenCleared() {
        let cleared = PumpFailureAcknowledgement.resolve(ack, suspected: false, latestMeetsLimits: false, podInsertTime: ack.podInsertTime)
        #expect(cleared == .init(fire: false, acknowledgement: nil))
        // and may fire again on the next tick
        let again = PumpFailureAcknowledgement.resolve(cleared.acknowledgement, suspected: true, latestMeetsLimits: true, podInsertTime: ack.podInsertTime)
        #expect(again.fire)
    }

    @Test("#resolve — a pod change re-arms")
    func rearmsOnPodChange() {
        let newPod = ackTime.timeIntervalSince1970 + 1800
        let outcome = PumpFailureAcknowledgement.resolve(ack, suspected: true, latestMeetsLimits: true, podInsertTime: newPod)
        #expect(outcome == .init(fire: true, acknowledgement: nil))
    }

    @Test("#resolve — pod change detected without a known pod at acknowledgement")
    func podChangeWithoutKnownPod() {
        let unknownPod = PumpFailureAcknowledgement(acknowledgedAt: ackTime, podInsertTime: nil)
        #expect(!unknownPod.podChanged(currentInsertTime: ackTime.timeIntervalSince1970 - 3600))
        #expect(unknownPod.podChanged(currentInsertTime: ackTime.timeIntervalSince1970 + 600))
        #expect(!unknownPod.podChanged(currentInsertTime: nil))
        #expect(!unknownPod.podChanged(currentInsertTime: 0))
    }

    // MARK: - Condition with real data

    private func alarmData(_ check: PumpDeliveryCheck, podInsertTime: TimeInterval?) -> AlarmData {
        var data = AlarmData.withGlucose(readings: check.glucose)
        data = AlarmData(
            bgReadings: data.bgReadings, predictionData: [], expireDate: nil, lastLoopTime: nil,
            latestOverrideStart: nil, latestOverrideEnd: nil, latestTempTargetStart: nil, latestTempTargetEnd: nil,
            recBolus: nil, COB: nil, sageInsertTime: nil, pumpInsertTime: podInsertTime, latestPumpVolume: nil,
            IOB: nil, recentBoluses: [], latestBattery: nil, latestBatteryIsCharging: nil, latestPumpBattery: nil,
            batteryHistory: [], recentCarbs: [], dbSizePercentage: nil
        )
        data.pumpDelivery = check
        return data
    }

    /// Holds the acknowledgement in place of `Storage`.
    private final class Box {
        var value: PumpFailureAcknowledgement?
    }

    private func condition(_ box: Box) -> PumpFailureCondition {
        PumpFailureCondition(load: { box.value }, save: { box.value = $0 })
    }

    @Test("#condition — acknowledge silences a real pod failure until glucose falls")
    func conditionAcknowledgeCycle() throws {
        let box = Box()
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var check = PumpDeliveryCheckTests.check(fixture)
        let pod = fixture.now.timeIntervalSince1970 - 2 * 24 * 3600
        let alarm = Alarm(type: .pumpFailure)
        let condition = condition(box)

        #expect(condition.evaluate(alarm: alarm, data: alarmData(check, podInsertTime: pod), now: fixture.now))

        box.value = .init(acknowledgedAt: fixture.now, podInsertTime: pod)
        #expect(!condition.evaluate(alarm: alarm, data: alarmData(check, podInsertTime: pod), now: fixture.now))
        #expect(box.value != nil)

        // Glucose drops well below the limit: the acknowledgement is spent.
        let latest = try #require(check.glucose.last)
        let later = latest.date.addingTimeInterval(300)
        check.glucose.append(GlucoseValue(sgv: 150, date: later))
        #expect(!condition.evaluate(alarm: alarm, data: alarmData(check, podInsertTime: pod), now: later))
        #expect(box.value == nil)
    }

    @Test("#condition — a new pod re-arms the alert")
    func conditionPodChange() throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        let check = PumpDeliveryCheckTests.check(fixture)
        let oldPod = fixture.now.timeIntervalSince1970 - 2 * 24 * 3600
        let box = Box()
        box.value = .init(acknowledgedAt: fixture.now.addingTimeInterval(-3600), podInsertTime: oldPod)

        let newPod = fixture.now.timeIntervalSince1970 - 600
        #expect(condition(box).evaluate(alarm: Alarm(type: .pumpFailure), data: alarmData(check, podInsertTime: newPod), now: fixture.now))
        #expect(box.value == nil)
    }
}
