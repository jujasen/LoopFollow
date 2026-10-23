// LoopFollow
// RemoteCommandRejectionTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Loop writes a Nightscout note when it rejects a remote command. These pin how LoopFollow
/// reads it, using the note Loop wrote on 2026-10-23 when a bolus reached Walter's phone late.
struct RemoteCommandRejectionTests {
    /// 2026-10-23 12:20:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_758_000)

    private static let push = #"{"sent-at":"2026-10-23T12:13:55.324Z","aps":{"alert":"Remote Bolus Entry: 0.50 U","content-available":1,"interruption-level":"time-sensitive"},"entered-by":"LoopFollow","bolus-entry":0.5,"expiration":"2026-10-23T12:18:55.324Z","remote-address":"LoopFollow","notes":"Sent via LoopFollow APNS","otp":"123456"}"#

    private static func note(
        error: String = "Error: Password sent at 2:13 has expired. Only the last 2 passwords are accepted. See LoopDocs for troubleshooting.",
        push: String = push,
        at time: String = "2026-10-23T12:16:17.000Z",
        enteredBy: String = "Bolus-oppføring 0,5 E"
    ) -> [String: AnyObject] {
        [
            "eventType": "Note" as NSString,
            "created_at": time as NSString,
            "enteredBy": enteredBy as NSString,
            "notes": "\(error)\n\(push)" as NSString,
        ]
    }

    @Test func readsLoopsNote() throws {
        let rejection = try #require(RemoteCommandRejection(treatment: Self.note()))
        #expect(rejection.command == "Bolus-oppføring 0,5 E")
        #expect(rejection.error.hasPrefix("Error: Password sent at 2:13 has expired."))
        #expect(rejection.passwordExpired)
        let delay = try #require(rejection.delay)
        #expect(delay == 142)
        // The late-push text, not Loop's raw error (the text itself depends on the language).
        #expect(!rejection.body.contains(rejection.error))
    }

    @Test func otherErrorsQuoteLoop() throws {
        let rejection = try #require(RemoteCommandRejection(treatment: Self.note(error: "Error: Bolus exceeds maximum of 3 U")))
        #expect(!rejection.passwordExpired)
        #expect(rejection.body.contains(rejection.error))
    }

    @Test func ignoresNotesNotFromLoopFollow() {
        #expect(RemoteCommandRejection(treatment: Self.note(push: #"{"remote-address":"Nightscout","entered-by":"Nightscout"}"#)) == nil)
        var plain = Self.note()
        plain["notes"] = "Walter sov godt" as NSString
        #expect(RemoteCommandRejection(treatment: plain) == nil)
        var bolus = Self.note()
        bolus["eventType"] = "Correction Bolus" as NSString
        #expect(RemoteCommandRejection(treatment: bolus) == nil)
    }

    @Test func tellsEachRejectionOnceAndOnlyWhileFresh() {
        let notes = [
            Self.note(at: "2026-10-23T12:16:17.000Z"),
            Self.note(at: "2026-10-23T12:05:00.000Z"),
            Self.note(at: "2026-10-22T11:04:41.000Z"),
        ]
        let fresh = RemoteCommandRejectionMonitor.newRejections(in: notes, since: nil, now: Self.now)
        #expect(fresh.map(\.noteDate) == [
            NightscoutUtils.parseDate("2026-10-23T12:05:00.000Z"),
            NightscoutUtils.parseDate("2026-10-23T12:16:17.000Z"),
        ])

        let told = NightscoutUtils.parseDate("2026-10-23T12:05:00.000Z")
        let later = RemoteCommandRejectionMonitor.newRejections(in: notes, since: told, now: Self.now)
        #expect(later.count == 1)
    }
}
