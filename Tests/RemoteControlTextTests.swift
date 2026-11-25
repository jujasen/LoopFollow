// LoopFollow
// RemoteControlTextTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The short texts on the remote control screen and in Home's command card.
/// Checked in English (the tests run with `-testLanguage en`).
struct RemoteControlTextTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test("#outcome — a short, plain answer for each state of a sent command")
    func outcome() {
        let sent = Self.now.addingTimeInterval(-5 * 60)
        func command(_ status: QueuedRemoteCommand.Status, units: Double? = 1, message: String? = nil, handled: Date? = nil) -> QueuedRemoteCommand {
            QueuedRemoteCommand(commandId: "c", objectId: "o", summary: "Bolus 1 U", units: units, sentAt: sent,
                                expiration: sent.addingTimeInterval(10 * 60), status: status, statusMessage: message, handledAt: handled)
        }
        let handled = sent.addingTimeInterval(60)
        let time = handled.formatted(date: .omitted, time: .shortened)
        #expect(RemoteCommandOutcome.text(command(.done, handled: handled), now: Self.now) == "Given at \(time)")
        #expect(RemoteCommandOutcome.text(command(.done, units: nil, handled: handled), now: Self.now) == "Done at \(time)")
        #expect(RemoteCommandOutcome.text(command(.pending), now: Self.now) == "Waiting for Loop")
        #expect(RemoteCommandOutcome.text(command(.rejected, message: "Bolus in progress"), now: Self.now) == "Rejected: Bolus in progress")
        #expect(RemoteCommandOutcome.text(command(.rejected), now: Self.now) == "Rejected by Loop")
        #expect(RemoteCommandOutcome.text(command(.failed, message: "Pump error"), now: Self.now) == "Not given: Pump error")
        #expect(RemoteCommandOutcome.text(command(.cancelled), now: Self.now) == "Withdrawn")
        // Pending past its expiration: it never reached Loop.
        #expect(RemoteCommandOutcome.text(command(.pending), now: sent.addingTimeInterval(20 * 60)) == "Never reached Loop")
        #expect(RemoteCommandOutcome.needsAttention(.uncertain))
        #expect(!RemoteCommandOutcome.needsAttention(.given))
    }
}
