// LoopFollow
// PumpFailureAcknowledgement.swift

import Foundation

/// «Jeg har sjekket» on the pump-delivery alert: the alert stays silent until the
/// situation it warned about is over — the latest reading no longer meets the limits
/// (glucose has come down or is falling) — or the pod is changed. After that it may
/// fire again.
struct PumpFailureAcknowledgement: Codable, Equatable {
    var acknowledgedAt: Date
    /// The pod's insert time (seconds since 1970) when acknowledged, if known.
    var podInsertTime: TimeInterval?

    /// Whether the alert may fire, and the acknowledgement to keep.
    struct Outcome: Equatable {
        let fire: Bool
        let acknowledgement: PumpFailureAcknowledgement?
    }

    /// - Parameters:
    ///   - suspected: the check currently suspects a failure
    ///   - latestMeetsLimits: whether the latest reading meets the alert's limits;
    ///     nil when that cannot be told (stale or missing data), which keeps the
    ///     acknowledgement rather than re-arming on a gap
    ///   - podInsertTime: the current pod's insert time, seconds since 1970
    static func resolve(
        _ acknowledgement: PumpFailureAcknowledgement?,
        suspected: Bool,
        latestMeetsLimits: Bool?,
        podInsertTime: TimeInterval?
    ) -> Outcome {
        guard let acknowledgement else {
            return Outcome(fire: suspected, acknowledgement: nil)
        }
        if acknowledgement.podChanged(currentInsertTime: podInsertTime) {
            return Outcome(fire: suspected, acknowledgement: nil)
        }
        if latestMeetsLimits == false {
            return Outcome(fire: false, acknowledgement: nil)
        }
        return Outcome(fire: false, acknowledgement: acknowledgement)
    }

    func podChanged(currentInsertTime: TimeInterval?) -> Bool {
        guard let current = currentInsertTime, current > 0 else { return false }
        if let known = podInsertTime, known > 0 {
            return current > known + 60
        }
        return current > acknowledgedAt.timeIntervalSince1970
    }
}
