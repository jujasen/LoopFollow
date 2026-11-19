// LoopFollow
// RemoteCommandInboxTests.swift

@testable import LoopFollow
import XCTest

final class RemoteCommandInboxTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func command(_ status: QueuedRemoteCommand.Status, handledAt: Date? = nil, units: Double? = 0.5) -> QueuedRemoteCommand {
        QueuedRemoteCommand(
            commandId: "A",
            objectId: "ns1",
            summary: "Bolus 0,5 E",
            units: units,
            sentAt: sentAt,
            expiration: sentAt.addingTimeInterval(RemoteCommandInbox.lifetime),
            status: status,
            handledAt: handledAt
        )
    }

    // MARK: Signature — the same bytes Loop's NightscoutService checks (RemoteCommandInboxTests there)

    func testSignatureMatchesLoop() {
        let signature = RemoteCommandInbox.sign(payload: #"{"bolus-entry":0.5,"command-id":"A"}"#, secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
        XCTAssertEqual(signature, "LfRxQ+eCLDBWwMd1nSq0WOL6K2XHZkMyjZQhzgAyKhA=")
    }

    func testSecretComesFromTheQRCode() {
        let url = "otpauth://totp/12345?algorithm=SHA1&digits=6&issuer=Loop&period=30&secret=ABCDEF234567"
        XCTAssertEqual(RemoteCommandInbox.secret(fromQRCodeURL: url), "ABCDEF234567")
        XCTAssertNil(RemoteCommandInbox.secret(fromQRCodeURL: "otpauth://totp/x?digits=6"))
    }

    // MARK: What goes to Nightscout

    func testPasswordAndReturnAddressStayOutOfNightscout() throws {
        let push: [String: Any] = [
            "bolus-entry": 0.5,
            "otp": "123456",
            "encrypted_return_notification": "secret",
            "return_notification": ["apns_key": "key"],
            "sent-at": "old",
            "expiration": "old",
            "remote-address": "LoopFollow",
        ]
        let payload = RemoteCommandInbox.inboxPayload(from: push, commandId: "A", sentAt: sentAt)
        XCTAssertNil(payload["otp"])
        XCTAssertNil(payload["encrypted_return_notification"])
        XCTAssertNil(payload["return_notification"])
        XCTAssertEqual(payload["command-id"] as? String, "A")
        XCTAssertEqual(payload["bolus-entry"] as? Double, 0.5)
        let sent = try XCTUnwrap(NightscoutUtils.parseDate(payload["sent-at"] as? String ?? ""))
        let expiration = try XCTUnwrap(NightscoutUtils.parseDate(payload["expiration"] as? String ?? ""))
        XCTAssertEqual(expiration.timeIntervalSince(sent), RemoteCommandInbox.lifetime, accuracy: 1)
    }

    func testTreatmentIsSignedOverItsPayload() throws {
        let payload: [String: Any] = ["bolus-entry": 0.5, "command-id": "A"]
        let treatment = try RemoteCommandInbox.treatment(payload: payload, commandId: "A", summary: "Bolus", secret: "S", sentAt: sentAt)
        XCTAssertEqual(treatment["eventType"] as? String, "Remote Command")
        XCTAssertEqual(treatment["status"] as? String, "pending")
        let json = try XCTUnwrap(treatment["payload"] as? String)
        XCTAssertEqual(treatment["signature"] as? String, RemoteCommandInbox.sign(payload: json, secret: "S"))
    }

    // MARK: What the card says

    func testWaitingTurnsIntoLapsedAfterExpiration() {
        let c = command(.pending)
        XCTAssertEqual(c.phase(now: sentAt.addingTimeInterval(60)), .waiting)
        XCTAssertEqual(c.phase(now: c.expiration.addingTimeInterval(30)), .waiting, "Loop's clock may be a little behind")
        XCTAssertEqual(c.phase(now: c.expiration.addingTimeInterval(61)), .lapsed)
    }

    func testRunningWithoutAnswerBecomesNoAnswer() {
        let c = command(.running, handledAt: sentAt.addingTimeInterval(60))
        XCTAssertEqual(c.phase(now: sentAt.addingTimeInterval(120)), .giving)
        XCTAssertEqual(c.phase(now: sentAt.addingTimeInterval(60 + 181)), .noAnswer)
    }

    func testABolusThatMayStillBeGivenBlocksAnother() {
        let now = sentAt.addingTimeInterval(120)
        XCTAssertTrue(command(.pending).mayStillDeliver(now: now))
        XCTAssertTrue(command(.running).mayStillDeliver(now: now))
        XCTAssertTrue(command(.pushOnly).mayStillDeliver(now: now))
        XCTAssertTrue(command(.uncertain).mayStillDeliver(now: now))
        XCTAssertFalse(command(.done).mayStillDeliver(now: now))
        XCTAssertFalse(command(.rejected).mayStillDeliver(now: now))
        XCTAssertFalse(command(.failed).mayStillDeliver(now: now))
        XCTAssertFalse(command(.pending).mayStillDeliver(now: sentAt.addingTimeInterval(RemoteCommandInbox.lifetime + 61)))
    }

    func testLoopsAnswerIsApplied() {
        var c = command(.pending)
        c.apply(treatment: ["_id": "ns1", "status": "done", "statusMessage": "Bolus-oppføring 0,5 E", "handledAt": "2027-01-15T08:01:00.000Z"])
        XCTAssertEqual(c.status, .done)
        XCTAssertEqual(c.phase(now: sentAt), .given)
        XCTAssertNotNil(c.handledAt)
    }

    func testWithdrawalStaysUnlessLoopGotThereFirst() {
        var c = command(.cancelled)
        c.apply(treatment: ["status": "pending"])
        XCTAssertEqual(c.status, .cancelled)
        c.apply(treatment: ["status": "running"])
        XCTAssertEqual(c.status, .running)
    }

    func testLapsedCommandIsLookedAtOnceMore() {
        let c = command(.pending)
        XCTAssertTrue(c.awaitsAnswer(now: c.expiration.addingTimeInterval(120)))
        XCTAssertFalse(c.awaitsAnswer(now: c.expiration.addingTimeInterval(10 * 60)))
    }

    func testSummaryOfABolusPayload() {
        let summary = LoopAPNSService.summary(of: ["bolus-entry": 0.5])
        XCTAssertEqual(summary.units, 0.5)
        XCTAssertNil(LoopAPNSService.summary(of: ["carbs-entry": 20.0]).units)
    }

    // MARK: A bolus seen in Nightscout

    func testPushOnlyBolusInNightscoutCountsAsGiven() {
        let c = command(.pushOnly)
        let found = RemoteCommandInbox.matches(commands: [c], boluses: [(sentAt.addingTimeInterval(140), 0.5)])
        XCTAssertEqual(found["A"], sentAt.addingTimeInterval(140))

        var seen = c
        seen.seenInNightscout = found["A"]
        // Long after the push expired it is still «given», not «can no longer be given».
        XCTAssertEqual(seen.phase(now: c.expiration.addingTimeInterval(30 * 60)), .given)
        XCTAssertFalse(seen.mayStillDeliver(now: sentAt.addingTimeInterval(200)))
    }

    func testOtherBolusesAreNotTakenForTheCommand() {
        let c = command(.pushOnly)
        let boluses: [(date: Date, units: Double)] = [
            (sentAt.addingTimeInterval(-10 * 60), 0.5), // before it was sent
            (sentAt.addingTimeInterval(60), 0.3), // another size
            (sentAt.addingTimeInterval(40 * 60), 0.5), // much later
        ]
        XCTAssertTrue(RemoteCommandInbox.matches(commands: [c], boluses: boluses).isEmpty)
    }

    func testEachBolusIsUsedOnce() {
        var first = command(.pushOnly)
        var second = QueuedRemoteCommand(commandId: "B", objectId: nil, summary: "Bolus 0,5 E", units: 0.5, sentAt: sentAt.addingTimeInterval(60), expiration: sentAt.addingTimeInterval(360), status: .pushOnly)
        let found = RemoteCommandInbox.matches(commands: [second, first], boluses: [(sentAt.addingTimeInterval(90), 0.5)])
        XCTAssertEqual(found.count, 1)
        XCTAssertNotNil(found["A"])
        first.seenInNightscout = Date()
        second.status = .done
        XCTAssertFalse(first.canBeMatchedToNightscout)
        XCTAssertFalse(second.canBeMatchedToNightscout)
    }

    func testRejectedCommandIsNotMatched() {
        XCTAssertTrue(RemoteCommandInbox.matches(commands: [command(.rejected)], boluses: [(sentAt.addingTimeInterval(60), 0.5)]).isEmpty)
    }

    func testOldSavedCommandsStillDecode() throws {
        let json = #"{"commandId":"A","summary":"Bolus 0,5 E","units":0.5,"sentAt":0,"expiration":300,"status":"pushOnly"}"#
        let c = try JSONDecoder().decode(QueuedRemoteCommand.self, from: Data(json.utf8))
        XCTAssertFalse(c.dismissed)
        XCTAssertNil(c.seenInNightscout)
    }
}
