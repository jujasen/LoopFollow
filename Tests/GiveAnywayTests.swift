// LoopFollow
// GiveAnywayTests.swift

@testable import LoopFollow
import XCTest

/// «Give anyway» on what Loop stopped, could not give or cut down, and the times that made Loop
/// stop boluses it should have given.
final class GiveAnywayTests: XCTestCase {
    /// 25 November 2026 at 16:21 UTC, the second meal Loop stopped that evening.
    private let now = Date(timeIntervalSince1970: 1_795_710_098)

    private func minutes(_ value: Double) -> Date {
        now.addingTimeInterval(value * 60)
    }

    private func command(_ status: QueuedRemoteCommand.Status, units: Double = 0.35, sentMinutesAgo: Double = 1, stoppedBy: [LoggedDose]? = nil, meal: MealBolusDetails? = nil) -> QueuedRemoteCommand {
        let sentAt = minutes(-sentMinutesAgo)
        return QueuedRemoteCommand(
            commandId: UUID().uuidString,
            objectId: "ns1",
            summary: "Bolus",
            units: units,
            sentAt: sentAt,
            expiration: sentAt.addingTimeInterval(RemoteCommandInbox.lifetime),
            status: status,
            handledAt: sentAt.addingTimeInterval(2),
            stoppedBy: stoppedBy,
            meal: meal
        )
    }

    private func meal(carbs: Double = 10, approved: Double = 0.95, saved: Bool? = nil, delivered: Double? = nil) -> MealBolusDetails {
        var details = MealBolusDetails(request: MealBolusRequest(carbs: carbs, absorptionHours: 1.5, foodType: "🍪 Marie kjeks", startTime: minutes(-1), bolus: approved, followsRecommendation: true))
        details.carbsSaved = saved
        details.deliveredUnits = delivered
        return details
    }

    // MARK: Times from Nightscout

    func testNightscoutTimesKeepTheirMilliseconds() throws {
        let date = try XCTUnwrap(NightscoutUtils.parseDate("2026-11-24T17:37:55.678Z"))
        let whole = try XCTUnwrap(NightscoutUtils.parseDate("2026-11-24T17:37:55Z"))
        XCTAssertEqual(date.timeIntervalSince(whole), 0.678, accuracy: 0.0005)
    }

    /// 24 November 2026: a bolus claimed to know of a dose at 17:37:55.000 when the dose was at
    /// 17:37:55.678, and Loop, which takes half a second as the same dose, stopped it twice.
    func testABolusClaimsToKnowTheLoggedDoseToTheMillisecond() throws {
        let logs: [[String: AnyObject]] = [[
            "created_at": "2026-11-24T20:20:00.000Z" as AnyObject,
            "doses": [["date": "2026-11-24T17:37:55.678Z", "units": 0.6, "source": "phone", "delivered": true]] as AnyObject,
        ]]
        let doses = try XCTUnwrap(DoseGuard.doses(inLogs: logs))
        let at = try XCTUnwrap(NightscoutUtils.parseDate("2026-11-24T20:22:03.152Z"))
        let known = DoseGuard.knownDosesUntil(logged: doses, commands: [], acknowledgedUntil: nil, now: at)
        let dose = try XCTUnwrap(NightscoutUtils.parseDate("2026-11-24T17:37:55.678Z"))
        XCTAssertLessThan(abs(known.timeIntervalSince(dose)), 0.002)
    }

    // MARK: What is offered

    func testAStoppedBolusCanBeGivenAnyway() {
        let stopper = LoggedDose(date: minutes(-15), units: 0.05, source: .remote)
        let stopped = command(.rejected, stoppedBy: [stopper])
        XCTAssertEqual(GiveAnyway.action(for: stopped, now: now), .bolus(units: 0.35))
    }

    func testABolusThePumpRefusedCanBeTriedAgain() {
        XCTAssertEqual(GiveAnyway.action(for: command(.failed, units: 0.45), now: now), .bolus(units: 0.45))
    }

    func testNothingIsOfferedWhileItMayStillBeGivenOrWasGiven() {
        XCTAssertNil(GiveAnyway.action(for: command(.pending), now: now))
        XCTAssertNil(GiveAnyway.action(for: command(.running), now: now))
        XCTAssertNil(GiveAnyway.action(for: command(.uncertain), now: now))
        XCTAssertNil(GiveAnyway.action(for: command(.done), now: now))
        XCTAssertNil(GiveAnyway.action(for: command(.cancelled), now: now))
    }

    func testNothingIsOfferedAfterHalfAnHour() {
        XCTAssertNil(GiveAnyway.action(for: command(.failed, sentMinutesAgo: 31), now: now))
    }

    func testAStoppedMealIsSentAgainForTheApprovedBolus() {
        let stopped = command(.rejected, units: 0.95, stoppedBy: [LoggedDose(date: minutes(-15), units: 0.05, source: .remote)], meal: meal(saved: false, delivered: 0))
        guard case let .meal(request) = GiveAnyway.action(for: stopped, now: now) else {
            return XCTFail("Expected the meal again")
        }
        XCTAssertEqual(request.carbs, 10)
        XCTAssertEqual(request.bolus, 0.95)
        XCTAssertEqual(request.foodType, "🍪 Marie kjeks")
        XCTAssertFalse(request.followsRecommendation, "Given anyway: what was approved, not Loop's lower recommendation")
    }

    func testAMealWhoseCarbsWereSavedGetsOnlyItsBolus() {
        let failed = command(.failed, units: 0.55, meal: meal(carbs: 8, approved: 0.55, saved: true, delivered: 0))
        XCTAssertEqual(GiveAnyway.action(for: failed, now: now), .bolus(units: 0.55))
    }

    /// 25 November 2026 16:06: 8 g with 0.55 U approved, and Loop gave 0.05 U.
    func testAMealBolusLoopCutDownOffersTheRest() {
        let given = command(.done, units: 0.55, meal: meal(carbs: 8, approved: 0.55, saved: true, delivered: 0.05))
        let action = GiveAnyway.action(for: given, now: now)
        XCTAssertEqual(action, .bolus(units: 0.5))
        XCTAssertTrue(GiveAnyway.isRest(action!, of: given, now: now))
    }

    func testAMealBolusGivenInFullOffersNothing() {
        let given = command(.done, units: 0.45, meal: meal(carbs: 8, approved: 0.45, saved: true, delivered: 0.45))
        XCTAssertNil(GiveAnyway.action(for: given, now: now))
    }

    func testTheDosesLoopNamedAreAcknowledgedWhenGivingAnyway() {
        let stopper = LoggedDose(date: minutes(-150), units: 0.6, source: .phone)
        let stopped = command(.rejected, stoppedBy: [stopper])
        let doseGuard = DoseGuard(defaults: UserDefaults(suiteName: "GiveAnywayTests-\(UUID().uuidString)")!)
        XCTAssertEqual(GiveAnyway.dosesToAcknowledge(for: stopped, guard: doseGuard, now: now), [stopper])

        // Once acknowledged, a bolus claims to know of it, so Loop gives it.
        doseGuard.acknowledge([stopper])
        let known = DoseGuard.knownDosesUntil(logged: [stopper], commands: [stopped], acknowledgedUntil: doseGuard.acknowledgedUntil, now: now)
        XCTAssertGreaterThanOrEqual(known, stopper.date)
    }
}
