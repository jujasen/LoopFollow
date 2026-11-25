// LoopFollow
// RemoteControlStatus.swift

import Foundation

/// The «Loop is responding» row at the top of Remote: whether Loop runs, when it
/// last did, and how commands reach it.
enum LoopResponseStatus {
    static func title(_ freshness: LoopFreshness) -> String {
        switch freshness {
        case .fresh:
            return String(localized: "Loop is responding", table: "RemoteControl")
        case .aging:
            return String(localized: "Loop is a little late", table: "RemoteControl")
        case .stale:
            return String(localized: "Loop is not responding", table: "RemoteControl")
        case .unknown:
            return String(localized: "No word from Loop yet", table: "RemoteControl")
        }
    }

    /// - Parameter viaNightscout: commands wait in Nightscout until Loop fetches them (the inbox);
    ///   otherwise they go as a push only.
    static func detail(lastLoop: Date?, now: Date, viaNightscout: Bool) -> String {
        let route = viaNightscout
            ? String(localized: "commands go via Nightscout", table: "RemoteControl")
            : String(localized: "commands go as a push only", table: "RemoteControl")
        guard let lastLoop else {
            return viaNightscout
                ? String(localized: "Commands go via Nightscout", table: "RemoteControl")
                : String(localized: "Commands go as a push only", table: "RemoteControl")
        }
        let at = lastLoop.formatted(date: .omitted, time: .shortened)
        switch LoopFreshness(lastLoop: lastLoop, now: now) {
        case .fresh, .unknown:
            return String(format: String(localized: "Last run %1$@ · %2$@", table: "RemoteControl", comment: "1: time of Loop's last run, 2: how commands reach Loop"), at, route)
        case .aging, .stale:
            let ago = HomeDurationFormat.hoursMinutes(now.timeIntervalSince(lastLoop))
            let wait = viaNightscout
                ? String(localized: "commands wait until Loop runs again", table: "RemoteControl")
                : String(localized: "a push may wait until Loop is opened", table: "RemoteControl")
            return String(format: String(localized: "Last run %1$@ (%2$@ ago) · %3$@", table: "RemoteControl", comment: "1: time of Loop's last run, 2: how long ago, 3: what happens to commands"), at, ago, wait)
        }
    }
}

/// The subtitle of the Override row: the active override and how long it has left.
enum OverrideStatusText {
    static func subtitle(name: String?, endAt: TimeInterval?, now: Date) -> String {
        guard let name, !name.isEmpty else {
            return String(localized: "None active", table: "RemoteControl", comment: "Override row when no override is on")
        }
        guard let endAt else {
            return String(format: String(localized: "%@ · on until stopped", table: "RemoteControl", comment: "1: override name; an override without an end"), name)
        }
        let remaining = endAt - now.timeIntervalSince1970
        guard remaining > 0 else { return name }
        let left: String
        if remaining >= 24 * 3600 {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.day, .hour]
            formatter.maximumUnitCount = 2
            left = formatter.string(from: remaining) ?? ""
        } else {
            left = HomeDurationFormat.hoursMinutes(remaining)
        }
        return String(format: String(localized: "%1$@ · %2$@ left", table: "RemoteControl", comment: "1: override name, 2: time left, e.g. 1 h 20 min"), name, left)
    }
}
