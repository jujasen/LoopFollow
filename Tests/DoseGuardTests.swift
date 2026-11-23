// LoopFollow
// DoseGuardTests.swift

@testable import LoopFollow
import XCTest

/// Which doses count as someone else's, and what a bolus sent from here claims to know.
final class DoseGuardTests: XCTestCase {
    /// 20 November 2026 at 22:17 UTC, the evening two corrections came two minutes apart.
    private let now = Date(timeIntervalSince1970: 1_795_385_820)

    private func minutes(_ value: Double) -> Date {
        now.addingTimeInterval(value * 60)
    }

    private func dose(_ source: LoggedDose.Source, _ units: Double, minutesAgo: Double) -> LoggedDose {
        LoggedDose(date: minutes(-minutesAgo), units: units, source: source)
    }

    private func command(_ status: QueuedRemoteCommand.Status, units: Double = 0.5, sentMinutesAgo: Double, handledMinutesAgo: Double? = nil, stoppedBy: [LoggedDose]? = nil) -> QueuedRemoteCommand {
        let sentAt = minutes(-sentMinutesAgo)
        return QueuedRemoteCommand(
            commandId: UUID().uuidString,
            objectId: "ns1",
            summary: "Bolus",
            units: units,
            sentAt: sentAt,
            expiration: sentAt.addingTimeInterval(RemoteCommandInbox.lifetime),
            status: status,
            handledAt: handledMinutesAgo.map { minutes(-$0) },
            stoppedBy: stoppedBy
        )
    }

    private func iso(_ date: Date) -> String {
        RemoteCommandInbox.format(date)
    }

    // MARK: Loop's log

    func testTheNewestLogIsRead() {
        let old: [String: AnyObject] = [
            "eventType": "Manual Dose Log" as AnyObject,
            "created_at": iso(minutes(-30)) as AnyObject,
            "doses": [["date": iso(minutes(-40)), "units": 0.2, "source": "phone", "delivered": true]] as AnyObject,
        ]
        let new: [String: AnyObject] = [
            "eventType": "Manual Dose Log" as AnyObject,
            "created_at": iso(minutes(-1)) as AnyObject,
            "doses": [
                ["date": iso(minutes(-2)), "units": 0.3, "source": "phone", "delivered": true],
                ["date": iso(minutes(-40)), "units": 0.2, "source": "eveningWatch", "delivered": true],
            ] as AnyObject,
        ]
        let doses = DoseGuard.doses(inLogs: [new, old])
        XCTAssertEqual(doses?.map(\.units), [0.2, 0.3], "oldest first")
        XCTAssertEqual(doses?.map(\.source), [.eveningWatch, .phone])
        XCTAssertEqual(doses?.last?.date.timeIntervalSince1970 ?? 0, minutes(-2).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNil(DoseGuard.doses(inLogs: []))
    }

    func testAnUnknownSourceIsStillSomeoneElsesDose() {
        let dose = LoggedDose(document: ["date": iso(now), "units": 0.4, "source": "somethingNew"])
        XCTAssertEqual(dose?.source, .phone)
        XCTAssertNil(LoggedDose(document: ["date": iso(now), "units": 0]))
        XCTAssertNil(LoggedDose(document: ["units": 0.4]))
    }

    // MARK: Whose dose

    func testADoseOnThePhoneIsSomeoneElsesForHalfAnHour() {
        let logged = [dose(.phone, 0.3, minutesAgo: 2), dose(.phone, 0.4, minutesAgo: 31)]
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: logged, commands: [], now: now).map(\.units), [0.3])
    }

    func testARemoteBolusSentFromHereIsNotSomeoneElses() {
        let logged = [dose(.remote, 0.5, minutesAgo: 4)]
        let mine = command(.done, sentMinutesAgo: 5, handledMinutesAgo: 3.9)
        XCTAssertTrue(DoseGuard.fromElsewhere(logged: logged, commands: [mine], now: now).isEmpty)
    }

    func testARemoteBolusFromAnotherPhoneIsSomeoneElses() {
        let logged = [dose(.remote, 0.5, minutesAgo: 4)]
        // Nothing sent from here; and a bolus of another size from here does not explain it.
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: logged, commands: [], now: now).count, 1)
        let other = command(.done, units: 0.2, sentMinutesAgo: 5, handledMinutesAgo: 3.9)
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: logged, commands: [other], now: now).count, 1)
        // One from here that Loop rejected was never given, so it does not explain it either.
        let rejected = command(.rejected, sentMinutesAgo: 5, handledMinutesAgo: 3.9)
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: logged, commands: [rejected], now: now).count, 1)
    }

    func testTheDosesThatStoppedABolusCountEvenBeforeTheLogArrives() {
        let stopper = dose(.phone, 0.3, minutesAgo: 2)
        let stopped = command(.rejected, sentMinutesAgo: 1, handledMinutesAgo: 0.5, stoppedBy: [stopper])
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: [], commands: [stopped], now: now), [stopper])
        // In the log too: listed once.
        XCTAssertEqual(DoseGuard.fromElsewhere(logged: [stopper], commands: [stopped], now: now), [stopper])
    }

    // MARK: What a bolus claims to know

    func testWithNothingKnownABolusClaimsOnlyOldKnowledge() {
        let known = DoseGuard.knownDosesUntil(logged: [], commands: [], acknowledgedUntil: nil, now: now)
        XCTAssertEqual(known, now.addingTimeInterval(-DoseGuard.lookBack))
    }

    func testABolusKnowsOfOlderDosesAndOfItsOwn() {
        let logged = [dose(.phone, 0.4, minutesAgo: 50), dose(.remote, 0.5, minutesAgo: 10)]
        let mine = command(.done, sentMinutesAgo: 11, handledMinutesAgo: 9.9)
        let known = DoseGuard.knownDosesUntil(logged: logged, commands: [mine], acknowledgedUntil: nil, now: now)
        // Loop wrote its answer just after the dose was requested.
        XCTAssertEqual(known, minutes(-9.9))
    }

    func testABolusDoesNotClaimToKnowADoseTheUserWasNotWarnedAbout() {
        // 0.30 U on the phone two minutes ago; LoopFollow has it in the log, but nobody was asked.
        let logged = [dose(.phone, 0.4, minutesAgo: 50), dose(.phone, 0.3, minutesAgo: 2)]
        let known = DoseGuard.knownDosesUntil(logged: logged, commands: [], acknowledgedUntil: nil, now: now)
        XCTAssertLessThan(known, minutes(-2), "Loop must find the dose later than what the bolus knows, and stop it")
        XCTAssertGreaterThanOrEqual(known, minutes(-50))
    }

    func testAfterTheWarningTheBolusKnowsOfTheDose() {
        let logged = [dose(.phone, 0.3, minutesAgo: 2)]
        let known = DoseGuard.knownDosesUntil(logged: logged, commands: [], acknowledgedUntil: minutes(-2), now: now)
        XCTAssertEqual(known, minutes(-2))
    }

    func testANewerDoseThanTheOneAcknowledgedIsNotKnown() {
        let logged = [dose(.phone, 0.3, minutesAgo: 10), dose(.phone, 0.2, minutesAgo: 1)]
        let known = DoseGuard.knownDosesUntil(logged: logged, commands: [], acknowledgedUntil: minutes(-10), now: now)
        XCTAssertGreaterThanOrEqual(known, minutes(-10))
        XCTAssertLessThan(known, minutes(-1))
    }

    func testAStoppedBolusCanBeSentAgainOnceItsDosesAreAcknowledged() {
        // The log never arrived here; Loop named the dose when it stopped the first bolus.
        let stopper = dose(.phone, 0.3, minutesAgo: 2)
        let stopped = command(.rejected, sentMinutesAgo: 1, handledMinutesAgo: 0.5, stoppedBy: [stopper])
        let before = DoseGuard.knownDosesUntil(logged: [], commands: [stopped], acknowledgedUntil: nil, now: now)
        XCTAssertLessThan(before, stopper.date)
        let after = DoseGuard.knownDosesUntil(logged: [], commands: [stopped], acknowledgedUntil: stopper.date, now: now)
        XCTAssertEqual(after, stopper.date)
    }

    func testAcknowledgingIsRememberedAndOnlyMovesForward() {
        let suite = "DoseGuardTests"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let guardA = DoseGuard(defaults: defaults)
        XCTAssertNil(guardA.acknowledgedUntil)
        guardA.acknowledge([dose(.phone, 0.3, minutesAgo: 2)])
        guardA.acknowledge([dose(.phone, 0.3, minutesAgo: 20)])
        XCTAssertEqual(DoseGuard(defaults: defaults).acknowledgedUntil?.timeIntervalSince1970 ?? 0, minutes(-2).timeIntervalSince1970, accuracy: 0.001)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: Loop's answer

    func testABolusLoopStoppedSaysWhichDoseItMissed() {
        var c = command(.pending, sentMinutesAgo: 1)
        c.apply(treatment: [
            "status": "rejected",
            "statusMessage": "Nothing was given: 0.3 U was given on this phone at 22:15, and the sender had not seen it.",
            "handledAt": iso(minutes(-0.5)),
            "statusDetails": ["reason": "unknownDoses", "doses": [["date": iso(minutes(-2)), "units": 0.3, "source": "phone", "delivered": true]]],
        ])
        XCTAssertEqual(c.phase(now: now), .stopped)
        XCTAssertEqual(c.stoppedBy?.map(\.units), [0.3])
        XCTAssertFalse(c.mayStillDeliver(now: now))
        XCTAssertNotNil(RemoteCommandText.notification(c, now: now))

        // Stored and read back with the doses.
        let data = try? JSONEncoder().encode(c)
        let decoded = data.flatMap { try? JSONDecoder().decode(QueuedRemoteCommand.self, from: $0) }
        XCTAssertEqual(decoded?.stoppedBy, c.stoppedBy)
    }

    func testAnOrdinaryRejectionIsNotAStop() {
        var c = command(.pending, sentMinutesAgo: 1)
        c.apply(treatment: ["status": "rejected", "statusMessage": "Exceeds maximum bolus", "statusDetails": ["reason": "somethingElse"]])
        XCTAssertEqual(c.phase(now: now), .rejected)
        XCTAssertNil(c.stoppedBy)
    }
}
