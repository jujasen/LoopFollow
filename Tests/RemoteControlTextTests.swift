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

    @Test("#loopStatus — whether Loop responds and how commands reach it")
    func loopStatus() {
        let at = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let recent = Self.now.addingTimeInterval(-2 * 60)
        #expect(LoopResponseStatus.title(.fresh) == "Loop is responding")
        #expect(LoopResponseStatus.title(.stale) == "Loop is not responding")
        #expect(LoopResponseStatus.detail(lastLoop: recent, now: Self.now, viaNightscout: true)
            == "Last run \(at(recent)) · commands go via Nightscout")
        let late = Self.now.addingTimeInterval(-28 * 60)
        #expect(LoopResponseStatus.detail(lastLoop: late, now: Self.now, viaNightscout: true)
            == "Last run \(at(late)) (28 min ago) · commands wait until Loop runs again")
        #expect(LoopResponseStatus.detail(lastLoop: late, now: Self.now, viaNightscout: false)
            == "Last run \(at(late)) (28 min ago) · a push may wait until Loop is opened")
        #expect(LoopResponseStatus.detail(lastLoop: nil, now: Self.now, viaNightscout: false) == "Commands go as a push only")
    }

    @Test("#override — the active override and the time it has left")
    func overrideSubtitle() {
        let now = Self.now
        #expect(OverrideStatusText.subtitle(name: nil, endAt: nil, now: now) == "None active")
        #expect(OverrideStatusText.subtitle(name: "🧈 Fett og protein", endAt: now.timeIntervalSince1970 + 80 * 60, now: now)
            == "🧈 Fett og protein · 1 h 20 min left")
        #expect(OverrideStatusText.subtitle(name: "Syk", endAt: nil, now: now) == "Syk · on until stopped")
        #expect(OverrideStatusText.subtitle(name: "Syk", endAt: now.timeIntervalSince1970 - 10, now: now) == "Syk")
    }
}
