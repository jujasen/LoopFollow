// LoopFollow
// DeviceLifecycle.swift

import Foundation

/// Where a CGM sensor or a pod is in its life, worked out from the start time
/// Nightscout has for it. Mirrors the lifecycle Loop shows on its Dexcom G7 and
/// Omnipod screens: warmup, then the nominal lifetime, then a grace period.
struct DeviceLifecycle: Equatable {
    enum Phase: Equatable {
        case warmup
        case active
        case grace
        case expired
    }

    enum Level: Equatable {
        case normal
        case warning
        case critical
    }

    let start: Date
    var warmup: TimeInterval = 0
    let lifetime: TimeInterval
    var grace: TimeInterval = 0
    /// Remaining lifetime at which the bar turns from normal to warning.
    var warningThreshold: TimeInterval = 24 * 3600

    var warmupEnd: Date { start.addingTimeInterval(warmup) }
    var expiration: Date { start.addingTimeInterval(lifetime) }
    var graceEnd: Date { expiration.addingTimeInterval(grace) }

    func phase(at now: Date) -> Phase {
        if now < warmupEnd { return .warmup }
        if now < expiration { return .active }
        if now < graceEnd { return .grace }
        return .expired
    }

    /// Time left of the current phase; nil once the device is past its grace period.
    func remaining(at now: Date) -> TimeInterval? {
        switch phase(at: now) {
        case .warmup: return warmupEnd.timeIntervalSince(now)
        case .active: return expiration.timeIntervalSince(now)
        case .grace: return graceEnd.timeIntervalSince(now)
        case .expired: return nil
        }
    }

    /// How full the bar is: warmup fills up to its end, the lifetime fills as it is
    /// used up, and anything past expiry shows a full bar.
    func progress(at now: Date) -> Double {
        let fraction: Double
        switch phase(at: now) {
        case .warmup:
            fraction = now.timeIntervalSince(start) / warmup
        case .active:
            fraction = now.timeIntervalSince(start) / lifetime
        case .grace, .expired:
            fraction = 1
        }
        return min(1, max(0, fraction))
    }

    func level(at now: Date) -> Level {
        switch phase(at: now) {
        case .warmup:
            return .normal
        case .active:
            return expiration.timeIntervalSince(now) <= warningThreshold ? .warning : .normal
        case .grace, .expired:
            return .critical
        }
    }
}

/// The CGM behind the readings, which decides how long a sensor lasts.
enum SensorKind: Equatable {
    case dexcomG7
    case dexcomG6
    case libre
    case other

    /// Recognizes the sensor from the entries' `device` field ("Dexcom G7 DXCMKW",
    /// "com.dexcom.g7app", …) or, failing that, from the sensor ID Loop writes into
    /// the Sensor Start note (G7 sensors advertise as "DXCM…").
    static func detect(deviceName: String?, sensorID: String?) -> SensorKind {
        let name = (deviceName ?? "").lowercased()
        if name.contains("g7") { return .dexcomG7 }
        if name.contains("g6") { return .dexcomG6 }
        if name.contains("libre") { return .libre }
        if let sensorID, sensorID.uppercased().hasPrefix("DXCM") { return .dexcomG7 }
        return .other
    }

    var displayName: String {
        switch self {
        case .dexcomG7: return "Dexcom G7"
        case .dexcomG6: return "Dexcom G6"
        case .libre: return "FreeStyle Libre"
        case .other: return String(localized: "Sensor", table: "DeviceStatus", comment: "Name of a CGM sensor whose model is unknown")
        }
    }

    /// Name of the picture in the asset catalog, if there is one for this sensor.
    var imageName: String? {
        self == .dexcomG7 ? "dexcom_g7" : nil
    }

    func lifecycle(startingAt start: Date) -> DeviceLifecycle {
        switch self {
        case .dexcomG7:
            // G7SensorKit: 10 days, 27 min warmup, 12 h grace period.
            return DeviceLifecycle(start: start, warmup: 27 * 60, lifetime: 10 * 86400, grace: 12 * 3600)
        case .dexcomG6:
            return DeviceLifecycle(start: start, warmup: 2 * 3600, lifetime: 10 * 86400)
        case .libre:
            return DeviceLifecycle(start: start, warmup: 3600, lifetime: 14 * 86400)
        case .other:
            return DeviceLifecycle(start: start, lifetime: 10 * 86400)
        }
    }

    /// Pulls "DXCMKW" out of Loop's Sensor Start note "SensorID: DXCMKW".
    static func sensorID(fromNotes notes: String?) -> String? {
        guard let notes, let range = notes.range(of: "SensorID:") else { return nil }
        let id = notes[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        return (id?.isEmpty ?? true) ? nil : id
    }
}

/// The insulin pump side: an Omnipod, or any other pump whose infusion set is
/// changed every three days.
enum PumpKind: Equatable {
    case omnipod
    case other

    /// Recognizes an Omnipod from the device status' `pump.model` ("Omnipod DASH",
    /// "Dash", "Eros").
    static func detect(model: String?) -> PumpKind {
        let model = (model ?? "").lowercased()
        if model.contains("omnipod") || model.contains("dash") || model.contains("eros") {
            return .omnipod
        }
        return .other
    }

    var shortName: String {
        switch self {
        case .omnipod: return String(localized: "Pod", table: "DeviceStatus", comment: "Short name of an Omnipod pod")
        case .other: return String(localized: "Infusion set", table: "DeviceStatus", comment: "Short name of a pump's infusion set")
        }
    }

    var imageName: String? {
        self == .omnipod ? "omnipod" : nil
    }

    func lifecycle(startingAt start: Date) -> DeviceLifecycle {
        switch self {
        case .omnipod:
            // OmnipodKit: 72 h nominal life; the pod stops delivering at 80 h.
            return DeviceLifecycle(start: start, lifetime: 72 * 3600, grace: 8 * 3600)
        case .other:
            return DeviceLifecycle(start: start, lifetime: 72 * 3600)
        }
    }
}
