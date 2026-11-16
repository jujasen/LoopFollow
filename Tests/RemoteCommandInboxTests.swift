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
}
