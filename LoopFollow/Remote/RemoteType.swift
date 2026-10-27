// LoopFollow
// RemoteType.swift

import Foundation

enum RemoteType: String, Codable {
    case none = "None"
    case trc = "Trio Remote Control"
    case loopAPNS = "Loop APNS"

    /// User-facing name. `rawValue` is persisted and must not change.
    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "Remote type: no remote control")
        case .trc: return String(localized: "Trio Remote Control")
        case .loopAPNS: return String(localized: "Loop APNS")
        }
    }
}
