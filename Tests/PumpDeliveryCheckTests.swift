// LoopFollow
// PumpDeliveryCheckTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct PumpDeliveryCheckTests {
    private static let oslo = TimeZone(identifier: "Europe/Oslo")!

    private static func check(_ fixture: PumpDeliveryFixtures.Fixture) -> PumpDeliveryCheck {
        let now = fixture.now
        func at(_ offset: Int) -> Date { now.addingTimeInterval(TimeInterval(offset)) }
        return PumpDeliveryCheck(
            glucose: fixture.glucose.map { GlucoseValue(sgv: $0.1, date: at($0.0)) },
            doses: fixture.doses.map { .init(start: at($0.0), end: at($0.0), units: $0.1) },
            carbs: fixture.carbs.map { .init(date: at($0.0), grams: $0.1, absorption: $0.2 * 60) },
            sensitivity: .init(items: PumpDeliveryFixtures.sensitivityMmol.map { .init(secondsFromMidnight: $0.0, value: $0.1 * 18) }, timeZone: oslo),
            carbRatio: .init(items: PumpDeliveryFixtures.carbRatio.map { .init(secondsFromMidnight: $0.0, value: $0.1) }, timeZone: oslo),
            curve: .init(peak: 55 * 60, duration: 6 * 3600, delay: 10 * 60)
        )
    }

    // MARK: - Insulin curve

    @Test("#curve — all insulin left before the delay, none after the duration")
    func curveEnds() {
        let curve = PumpDeliveryCheck.InsulinCurve(peak: 55 * 60, duration: 6 * 3600, delay: 10 * 60)
        #expect(curve.remaining(after: 0) == 1)
        #expect(curve.remaining(after: 10 * 60) == 1)
        #expect(curve.remaining(after: 6 * 3600 + 10 * 60) == 0)
        let samples = stride(from: 0.0, through: 6.5 * 3600, by: 300).map(curve.remaining(after:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test("#curve — Loop's presets by insulin model")
    func curvePresets() {
        #expect(PumpDeliveryCheck.InsulinCurve(model: "fiasp").peak == 55 * 60)
        #expect(PumpDeliveryCheck.InsulinCurve(model: "rapidActingChild").peak == 65 * 60)
        #expect(PumpDeliveryCheck.InsulinCurve(model: "rapidActingAdult").peak == 75 * 60)
    }

    // MARK: - Real episodes

    @Test("#history — fires at both pod failures and today, stays quiet at other highs",
          arguments: PumpDeliveryFixtures.all.map(\.name))
    func history(name: String) throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.name == name })
        let check = Self.check(fixture)
        let latest = try #require(check.glucose.last)
        let assessment = try #require(check.assess(at: latest))

        // Same model as the Python one the limits were tuned with.
        #expect(abs(assessment.unexplainedRise - fixture.unexplainedRise) < 2)
        #expect(abs(assessment.insulinDrop - fixture.insulinDrop) < 2)

        let fired = check.suspectedFailure(now: fixture.now, limits: .init()) != nil
        #expect(fired == fixture.shouldFire)
    }

    // MARK: - Guards

    @Test("#guards — no alarm on stale glucose")
    func staleGlucose() throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        let check = Self.check(fixture)
        #expect(check.suspectedFailure(now: fixture.now.addingTimeInterval(15 * 60), limits: .init()) == nil)
    }

    @Test("#guards — no alarm when the run of readings has a gap")
    func gapInReadings() throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var check = Self.check(fixture)
        check.glucose.removeAll { (-20 * 60 ... -5 * 60).contains($0.date.timeIntervalSince(fixture.now)) }
        #expect(check.suspectedFailure(now: fixture.now, limits: .init()) == nil)
    }

    @Test("#guards — no alarm when the insulin given was too little to show")
    func littleInsulin() throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var check = Self.check(fixture)
        check.doses = []
        #expect(check.suspectedFailure(now: fixture.now, limits: .init()) == nil)
    }

    // MARK: - Net basal

    @Test("#basal — net against the schedule, clipped to the window")
    func netBasal() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = PumpDeliveryCheck.Schedule(items: [.init(secondsFromMidnight: 0, value: 0.6)], timeZone: Self.oslo)
        let rates: [(rate: Double, date: Date)] = [
            (0, start), (0, start.addingTimeInterval(1800)), // 30 min suspended
            (1.2, start.addingTimeInterval(1800)), (1.2, start.addingTimeInterval(3600)), // 30 min at double
        ]
        let doses = PumpDeliveryCheck.netBasal(rates: rates, scheduled: schedule, from: start, to: start.addingTimeInterval(3000))
        let suspended = doses.filter { $0.end <= start.addingTimeInterval(1800) }.map(\.units).reduce(0, +)
        let raised = doses.filter { $0.start >= start.addingTimeInterval(1800) }.map(\.units).reduce(0, +)
        #expect(abs(suspended - -0.3) < 1e-9)
        #expect(abs(raised - 0.2) < 1e-9) // 20 min up to `to`
    }

    // MARK: - Condition

    @Test("#condition — reads its limits from the alarm")
    func conditionLimits() throws {
        let fixture = try #require(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var data = AlarmData.withGlucose()
        data.pumpDelivery = Self.check(fixture)
        var alarm = Alarm(type: .pumpFailure)
        #expect(PumpFailureCondition().evaluate(alarm: alarm, data: data, now: fixture.now))
        alarm.aboveBG = 400
        #expect(!PumpFailureCondition().evaluate(alarm: alarm, data: data, now: fixture.now))
    }
}
