// LoopFollow
// LAAppGroupSettings.swift

import Foundation

// MARK: - Slot option enum

/// One displayable metric that can occupy a slot in the Live Activity 2×2 grid.
///
/// - `.none` is the empty/blank state — leaves the slot visually empty.
/// - Optional cases (isOptional == true) may display "—" for Dexcom-only users
///   whose setup does not provide that metric.
/// - All values are read from GlucoseSnapshot at render time inside the widget
///   extension; no additional App Group reads are required per slot.
enum LiveActivitySlotOption: String, CaseIterable, Codable {
    // Core glucose
    case none
    case delta
    case projectedBG
    case minMax
    // Loop metrics
    case iob
    case cob
    case recBolus
    case autosens
    case tdd
    // Pump / device
    case basal
    case pump
    case pumpBattery
    case battery
    case target
    case isf
    case carbRatio
    // Ages
    case sage
    case cage
    case iage
    // Other
    case carbsToday
    case override
    case profile

    /// Human-readable label shown in the slot picker in Settings.
    var displayName: String {
        switch self {
        case .none: String(localized: "Empty")
        case .delta: String(localized: "Delta")
        case .projectedBG: String(localized: "Projected BG")
        case .minMax: String(localized: "Min/Max")
        case .iob: String(localized: "IOB")
        case .cob: String(localized: "COB")
        case .recBolus: String(localized: "Rec. Bolus")
        case .autosens: String(localized: "Autosens")
        case .tdd: String(localized: "TDD")
        case .basal: String(localized: "Basal")
        case .pump: String(localized: "Pump")
        case .pumpBattery: String(localized: "Pump Battery")
        case .battery: String(localized: "Battery")
        case .target: String(localized: "Target")
        case .isf: String(localized: "ISF")
        case .carbRatio: String(localized: "CR")
        case .sage: String(localized: "SAGE")
        case .cage: String(localized: "CAGE")
        case .iage: String(localized: "IAGE")
        case .carbsToday: String(localized: "Carbs today")
        case .override: String(localized: "Override")
        case .profile: String(localized: "Profile")
        }
    }

    /// Short label used inside the MetricBlock on the Live Activity card.
    var gridLabel: String {
        switch self {
        case .none: ""
        case .delta: String(localized: "Delta", comment: "Short Live Activity grid label")
        case .projectedBG: String(localized: "Proj", comment: "Short Live Activity grid label")
        case .minMax: String(localized: "Min/Max", comment: "Short Live Activity grid label")
        case .iob: String(localized: "IOB", comment: "Short Live Activity grid label")
        case .cob: String(localized: "COB", comment: "Short Live Activity grid label")
        case .recBolus: String(localized: "Rec.", comment: "Short Live Activity grid label")
        case .autosens: String(localized: "Sens", comment: "Short Live Activity grid label")
        case .tdd: String(localized: "TDD", comment: "Short Live Activity grid label")
        case .basal: String(localized: "Basal", comment: "Short Live Activity grid label")
        case .pump: String(localized: "Pump", comment: "Short Live Activity grid label")
        case .pumpBattery: String(localized: "Pump%", comment: "Short Live Activity grid label")
        case .battery: String(localized: "Bat.", comment: "Short Live Activity grid label")
        case .target: String(localized: "Target", comment: "Short Live Activity grid label")
        case .isf: String(localized: "ISF", comment: "Short Live Activity grid label")
        case .carbRatio: String(localized: "CR", comment: "Short Live Activity grid label")
        case .sage: String(localized: "SAGE", comment: "Short Live Activity grid label")
        case .cage: String(localized: "CAGE", comment: "Short Live Activity grid label")
        case .iage: String(localized: "IAGE", comment: "Short Live Activity grid label")
        case .carbsToday: String(localized: "Carbs", comment: "Short Live Activity grid label")
        case .override: String(localized: "Ovrd", comment: "Short Live Activity grid label")
        case .profile: String(localized: "Prof", comment: "Short Live Activity grid label")
        }
    }

    /// True when the value is a glucose measurement and should be followed by
    /// the user's preferred unit label (mg/dL or mmol/L) in compact displays.
    var isGlucoseUnit: Bool {
        switch self {
        case .projectedBG, .delta, .minMax, .target, .isf: return true
        default: return false
        }
    }

    /// Options selectable for the lock-screen 2×2 grid. The active override is
    /// excluded — the card has a dedicated override/temp-target countdown row.
    /// It remains selectable for the single CarPlay/Watch slot, which has no
    /// such row.
    static var gridCases: [LiveActivitySlotOption] {
        allCases.filter { $0 != .override }
    }

    /// True when the underlying value may be nil (e.g. Dexcom-only users who have
    /// no Loop data). The widget renders "—" in those cases.
    var isOptional: Bool {
        switch self {
        case .none, .delta: false
        default: true
        }
    }
}

// MARK: - Lock screen layout

/// How the Live Activity lock screen card is drawn.
///
/// Mirrors Loop's own `LiveActivityMode`, which offers the same choice between a
/// plot and a plain readout. `.grid` stays the default so existing users' cards do
/// not change appearance on update.
enum LiveActivityLayout: String, CaseIterable, Codable {
    /// Large glucose readout with the configurable 2×2 metric grid.
    case grid

    /// Glucose chart with recent readings and the prediction, over a compact
    /// bottom row — the layout Loop calls "Plot and Row".
    case chart

    var displayName: String {
        switch self {
        case .grid: String(localized: "Value and Grid")
        case .chart: String(localized: "Plot and Row")
        }
    }
}

// MARK: - Default slot assignments

enum LiveActivitySlotDefaults {
    /// Top-left slot
    static let slot1: LiveActivitySlotOption = .iob
    /// Bottom-left slot
    static let slot2: LiveActivitySlotOption = .cob
    /// Top-right slot
    static let slot3: LiveActivitySlotOption = .projectedBG
    /// Bottom-right slot — intentionally empty until the user configures it
    static let slot4: LiveActivitySlotOption = .none
    /// Small widget (CarPlay / Watch Smart Stack) right slot
    static let smallWidgetSlot: LiveActivitySlotOption = .projectedBG

    static var all: [LiveActivitySlotOption] {
        [slot1, slot2, slot3, slot4]
    }
}

// MARK: - App Group settings

/// Minimal App Group settings needed by the Live Activity UI.
///
/// We keep this separate from Storage.shared to avoid target-coupling and
/// ensure the widget extension reads the same values as the app.
enum LAAppGroupSettings {
    private enum Keys {
        static let lowLineMgdl = "la.lowLine.mgdl"
        static let highLineMgdl = "la.highLine.mgdl"
        static let slots = "la.slots"
        static let smallWidgetSlot = "la.smallWidgetSlot"
        static let displayName = "la.displayName"
        static let showDisplayName = "la.showDisplayName"
        static let layout = "la.layout"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.current())
    }

    // MARK: - Thresholds (Write)

    static func setThresholds(lowMgdl: Double, highMgdl: Double) {
        defaults?.set(lowMgdl, forKey: Keys.lowLineMgdl)
        defaults?.set(highMgdl, forKey: Keys.highLineMgdl)
    }

    // MARK: - Thresholds (Read)

    static func thresholdsMgdl(fallbackLow: Double = 70, fallbackHigh: Double = 180) -> (low: Double, high: Double) {
        let low = defaults?.object(forKey: Keys.lowLineMgdl) as? Double ?? fallbackLow
        let high = defaults?.object(forKey: Keys.highLineMgdl) as? Double ?? fallbackHigh
        return (low, high)
    }

    // MARK: - Slot configuration (Write)

    /// Persists a 4-slot configuration to the App Group container.
    /// - Parameter slots: Array of exactly 4 `LiveActivitySlotOption` values;
    ///   extra elements are ignored, missing elements are filled with `.none`.
    static func setSlots(_ slots: [LiveActivitySlotOption]) {
        let raw = slots.prefix(4).map(\.rawValue)
        defaults?.set(raw, forKey: Keys.slots)
    }

    // MARK: - Slot configuration (Read)

    /// Returns the current 4-slot configuration, falling back to defaults
    /// if no configuration has been saved yet.
    static func slots() -> [LiveActivitySlotOption] {
        guard let raw = defaults?.stringArray(forKey: Keys.slots), raw.count == 4 else {
            return LiveActivitySlotDefaults.all
        }
        // .override is no longer a grid option (the card has a dedicated
        // override/temp-target row); selections stored by older versions
        // render as empty cells.
        return raw.map { LiveActivitySlotOption(rawValue: $0) ?? .none }
            .map { $0 == .override ? .none : $0 }
    }

    // MARK: - Small widget slot (Write)

    static func setSmallWidgetSlot(_ slot: LiveActivitySlotOption) {
        defaults?.set(slot.rawValue, forKey: Keys.smallWidgetSlot)
    }

    // MARK: - Small widget slot (Read)

    static func smallWidgetSlot() -> LiveActivitySlotOption {
        guard let raw = defaults?.string(forKey: Keys.smallWidgetSlot) else {
            return LiveActivitySlotDefaults.smallWidgetSlot
        }
        return LiveActivitySlotOption(rawValue: raw) ?? LiveActivitySlotDefaults.smallWidgetSlot
    }

    // MARK: - Lock screen layout

    static func setLayout(_ layout: LiveActivityLayout) {
        defaults?.set(layout.rawValue, forKey: Keys.layout)
    }

    static func layout() -> LiveActivityLayout {
        guard let raw = defaults?.string(forKey: Keys.layout) else { return .grid }
        return LiveActivityLayout(rawValue: raw) ?? .grid
    }

    // MARK: - Display Name

    static func setDisplayName(_ name: String, show: Bool) {
        defaults?.set(name, forKey: Keys.displayName)
        defaults?.set(show, forKey: Keys.showDisplayName)
    }

    static func displayName() -> String {
        defaults?.string(forKey: Keys.displayName) ?? "LoopFollow"
    }

    static func showDisplayName() -> Bool {
        defaults?.bool(forKey: Keys.showDisplayName) ?? false
    }
}
