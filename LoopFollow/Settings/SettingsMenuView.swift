// LoopFollow
// SettingsMenuView.swift

import SwiftUI
import UIKit

struct SettingsMenuView: View {
    @ObservedObject private var nightscoutURL = Storage.shared.url

    var body: some View {
        List {
            ForEach(SettingsRoute.menuSections(nightscoutConfigured: !nightscoutURL.value.isEmpty), id: \.0) { section, routes in
                Section(section.displayName) {
                    ForEach(routes) { route in
                        NavigationRow(title: route.title,
                                      icon: route.icon,
                                      value: route)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: – Sheet routing

enum SettingsSection: String, CaseIterable, Hashable {
    case data = "Data Settings"
    case display = "Display Settings"
    case app = "App Settings"
    case alarms = "Alarms"
    case integrations = "Integrations"
    case advanced = "Advanced Settings"

    var displayName: String {
        switch self {
        case .data: return String(localized: "Data Settings")
        case .display: return String(localized: "Display Settings")
        case .app: return String(localized: "App Settings")
        case .alarms: return String(localized: "Alarms")
        case .integrations: return String(localized: "Integrations")
        case .advanced: return String(localized: "Advanced Settings")
        }
    }
}

/// A single setting inside a settings screen, exposed to Menu search. Leaves
/// are not navigable on their own — a search hit opens the screen
/// (`SettingsRoute`) that contains it.
struct SettingsLeaf: Hashable {
    let title: String
    let keywords: [String]

    init(_ title: String, _ keywords: [String] = []) {
        self.title = title
        self.keywords = keywords
    }
}

enum SettingsRoute: Hashable, Identifiable {
    case settings
    case units
    case nightscout, dexcom
    case backgroundRefresh
    case general, graph
    case tabSettings
    case infoDisplay
    case alarmSettings
    case apn
    #if !targetEnvironment(macCatalyst)
        case liveActivity
    #endif
    case remote
    case importExport
    case calendar, contact
    case advanced
    case aggregatedStats

    var id: Self { self }

    // MARK: – Row presentation (single source of truth)

    /// Title shown in the Settings list and used for search matching.
    /// Non-row cases (`.settings`, `.aggregatedStats`) return "" and are never
    /// included in `menuSections`.
    var title: String {
        switch self {
        case .nightscout: return "Nightscout"
        case .dexcom: return "Dexcom"
        case .general: return String(localized: "General")
        case .graph: return String(localized: "Graph")
        case .infoDisplay: return String(localized: "Information Display")
        case .units: return String(localized: "Units and Metrics")
        case .tabSettings: return String(localized: "Tabs")
        case .backgroundRefresh: return String(localized: "Background Refresh")
        case .importExport: return String(localized: "Import/Export")
        case .apn: return "APN"
        #if !targetEnvironment(macCatalyst)
            case .liveActivity: return String(localized: "Live Activity")
        #endif
        case .remote: return String(localized: "Remote")
        case .alarmSettings: return String(localized: "Alarms")
        case .calendar: return String(localized: "Calendar")
        case .contact: return String(localized: "Contact")
        case .advanced: return String(localized: "Advanced")
        case .settings, .aggregatedStats: return ""
        }
    }

    var icon: String {
        switch self {
        case .nightscout: return "network"
        case .dexcom: return "sensor.tag.radiowaves.forward"
        case .general: return "gearshape"
        case .graph: return "chart.xyaxis.line"
        case .infoDisplay: return "info.circle"
        case .units: return "scalemass"
        case .tabSettings: return "rectangle.3.group"
        case .backgroundRefresh: return "arrow.clockwise"
        case .importExport: return "square.and.arrow.down"
        case .apn: return "bell.and.waves.left.and.right"
        #if !targetEnvironment(macCatalyst)
            case .liveActivity: return "dot.radiowaves.left.and.right"
        #endif
        case .remote: return "antenna.radiowaves.left.and.right"
        case .alarmSettings: return "bell.badge"
        case .calendar: return "calendar"
        case .contact: return "person.circle"
        case .advanced: return "exclamationmark.shield"
        case .settings, .aggregatedStats: return ""
        }
    }

    /// Extra synonyms so search finds a page by related terms, not just its title.
    var keywords: [String] {
        switch self {
        case .graph: return ["chart"]
        case .units: return ["mmol", "mgdl", "metrics"]
        case .infoDisplay: return ["info"]
        case .apn: return ["push", "notification"]
        #if !targetEnvironment(macCatalyst)
            case .liveActivity: return ["dynamic island", "lock screen"]
        #endif
        case .importExport: return ["import", "export", "backup"]
        default: return []
        }
    }

    /// The individual settings inside this screen, so Menu search can find a
    /// bottom-level setting (e.g. "Graph Basal") and open the screen containing
    /// it. Titles mirror the row (or section) titles in each screen's view —
    /// keep them in sync when adding or renaming rows.
    var leaves: [SettingsLeaf] {
        switch self {
        case .nightscout: return [
                SettingsLeaf(String(localized: "URL")),
                SettingsLeaf(String(localized: "Access Token"), ["token"]),
                SettingsLeaf(String(localized: "Enable WebSocket"), ["websocket", "real-time"]),
            ]
        case .dexcom: return [
                SettingsLeaf(String(localized: "User Name"), ["username"]),
                SettingsLeaf(String(localized: "Password")),
                SettingsLeaf(String(localized: "Server")),
            ]
        case .general: return [
                SettingsLeaf(String(localized: "Display App Badge"), ["badge"]),
                SettingsLeaf(String(localized: "Persistent Notification")),
                SettingsLeaf(String(localized: "Appearance"), ["dark mode", "light mode", "theme"]),
                SettingsLeaf(String(localized: "Display Stats")),
                SettingsLeaf(String(localized: "Display Small Graph")),
                SettingsLeaf(String(localized: "Color BG Text")),
                SettingsLeaf(String(localized: "Keep Screen Active"), ["screen lock", "screenlock"]),
                SettingsLeaf(String(localized: "Show Display Name")),
                SettingsLeaf(String(localized: "Snoozer emoji")),
                SettingsLeaf(String(localized: "Force portrait mode"), ["orientation", "landscape"]),
                SettingsLeaf(String(localized: "Time Zone Override"), ["timezone"]),
                SettingsLeaf(String(localized: "Speak BG"), ["voice", "speech"]),
                SettingsLeaf(String(localized: "Send anonymous usage stats"), ["telemetry", "diagnostics"]),
            ]
        case .graph: return [
                SettingsLeaf(String(localized: "Display Dots")),
                SettingsLeaf(String(localized: "Display Lines")),
                SettingsLeaf(String(localized: "Show DIA Lines"), ["dia"]),
                SettingsLeaf(String(localized: "Show −30 min Line"), ["-30"]),
                SettingsLeaf(String(localized: "Show −90 min Line"), ["-90"]),
                SettingsLeaf(String(localized: "Show Yesterday's BG"), ["yesterday"]),
                SettingsLeaf(String(localized: "Show Midnight Lines")),
                SettingsLeaf(String(localized: "Show Carb/Bolus Values"), ["carbs"]),
                SettingsLeaf(String(localized: "Show Carb Absorption")),
                SettingsLeaf(String(localized: "Treatments on Small Graph")),
                SettingsLeaf(String(localized: "Small Graph Height"), ["height"]),
                SettingsLeaf(String(localized: "Hours of Prediction"), ["prediction"]),
                SettingsLeaf(String(localized: "Prediction Style")),
                SettingsLeaf(String(localized: "Min Basal"), ["basal scale"]),
                SettingsLeaf(String(localized: "Min BG Scale")),
                SettingsLeaf(String(localized: "Show Days Back"), ["history", "days back"]),
            ]
        case .infoDisplay:
            return [SettingsLeaf(String(localized: "Hide Information Table"))]
                + InfoType.allCases.map { SettingsLeaf($0.name) }
        case .units: return [
                SettingsLeaf(String(localized: "Glucose Unit")),
                SettingsLeaf(String(localized: "Range Mode"), ["tir", "titr", "time in range"]),
                SettingsLeaf(String(localized: "Glycemic Metrics"), ["hba1c", "ehba1c", "gmi"]),
                SettingsLeaf(String(localized: "Variability"), ["standard deviation", "cv"]),
            ]
        case .backgroundRefresh: return [
                SettingsLeaf(String(localized: "Background Refresh Type"), ["silent tune", "bluetooth", "rileylink", "omnipod", "heartbeat"]),
            ]
        case .importExport: return [
                SettingsLeaf(String(localized: "Scan QR Code to Import Settings"), ["qr"]),
                SettingsLeaf(String(localized: "Export Settings To QR Code"), ["qr"]),
            ]
        case .apn: return [
                SettingsLeaf(String(localized: "APNS Key ID"), ["apns"]),
                SettingsLeaf(String(localized: "APNS Key"), ["apns", "p8"]),
            ]
        #if !targetEnvironment(macCatalyst)
            case .liveActivity: return [
                    SettingsLeaf(String(localized: "Enable Live Activity")),
                    SettingsLeaf(String(localized: "Restart Live Activity")),
                    SettingsLeaf(String(localized: "Grid Slots"), ["carplay", "watch"]),
                ]
        #endif
        case .remote: return [
                SettingsLeaf(String(localized: "Loop Remote Control")),
                SettingsLeaf(String(localized: "Trio Remote Control"), ["trc"]),
                SettingsLeaf(String(localized: "Favorite Foods"), ["favorites", "meals", "food"]),
                SettingsLeaf(String(localized: "Meal with Bolus")),
                SettingsLeaf(String(localized: "Meal with Fat/Protein")),
                SettingsLeaf(String(localized: "Guardrails"), ["max bolus", "max carbs", "max fat", "max protein"]),
                SettingsLeaf(String(localized: "Bolus Increment")),
                SettingsLeaf(String(localized: "Shared Secret")),
                SettingsLeaf(String(localized: "QR Code URL"), ["qr"]),
            ]
        case .alarmSettings: return [
                SettingsLeaf(String(localized: "All Alerts Snoozed"), ["snooze all"]),
                SettingsLeaf(String(localized: "All Sounds Muted"), ["mute all"]),
                SettingsLeaf(String(localized: "Day starts"), ["schedule", "day/night"]),
                SettingsLeaf(String(localized: "Night starts"), ["schedule", "day/night"]),
                SettingsLeaf(String(localized: "Override System Volume"), ["volume"]),
                SettingsLeaf(String(localized: "Audio During Calls")),
                SettingsLeaf(String(localized: "Ignore Zero BG")),
                SettingsLeaf(String(localized: "Auto-Snooze CGM Start"), ["autosnooze"]),
                SettingsLeaf(String(localized: "Volume Buttons Snooze Alarms")),
            ]
        case .calendar: return [
                SettingsLeaf(String(localized: "Save BG to Calendar"), ["watch", "carplay"]),
                SettingsLeaf(String(localized: "Calendar Text")),
            ]
        case .contact: return [
                SettingsLeaf(String(localized: "Enable Contact BG Updates"), ["watch face"]),
                SettingsLeaf(String(localized: "Background Color")),
                SettingsLeaf(String(localized: "Color Mode")),
                SettingsLeaf(String(localized: "Text Color")),
                SettingsLeaf(String(localized: "Show Trend")),
                SettingsLeaf(String(localized: "Show Delta")),
                SettingsLeaf(String(localized: "Show IOB")),
            ]
        case .advanced: return [
                SettingsLeaf(String(localized: "Download Treatments")),
                SettingsLeaf(String(localized: "Download Prediction")),
                SettingsLeaf(String(localized: "Graph Basal")),
                SettingsLeaf(String(localized: "Graph Bolus")),
                SettingsLeaf(String(localized: "Graph Carbs")),
                SettingsLeaf(String(localized: "Graph Other Treatments")),
                SettingsLeaf(String(localized: "BG Update Delay"), ["delay"]),
                SettingsLeaf(String(localized: "Debug Log Level"), ["logging"]),
            ]
        case .tabSettings, .settings, .aggregatedStats: return []
        }
    }

    /// Ordered, grouped list of the routes shown as rows in the Settings menu.
    /// Encodes the conditional visibility in one place so both the list and the
    /// Menu search stay in sync.
    static func menuSections(nightscoutConfigured: Bool) -> [(SettingsSection, [SettingsRoute])] {
        var display: [SettingsRoute] = [.general, .graph]
        if nightscoutConfigured {
            display.append(.infoDisplay)
        }
        display += [.units, .tabSettings]

        var app: [SettingsRoute] = [.backgroundRefresh, .importExport, .apn]
        #if !targetEnvironment(macCatalyst)
            app.append(.liveActivity)
        #endif
        if nightscoutConfigured {
            app.append(.remote)
        }

        return [
            (.data, [.nightscout, .dexcom]),
            (.display, display),
            (.app, app),
            (.alarms, [.alarmSettings]),
            (.integrations, [.calendar, .contact]),
            (.advanced, [.advanced]),
        ]
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .settings: SettingsMenuView()
        case .units: UnitsSettingsView()
        case .nightscout: NightscoutSettingsView(viewModel: .init())
        case .dexcom: DexcomSettingsView(viewModel: .init())
        case .backgroundRefresh: BackgroundRefreshSettingsView(viewModel: .init())
        case .general: GeneralSettingsView()
        case .graph: GraphSettingsView()
        case .tabSettings: TabCustomizationModal()
        case .infoDisplay: InfoDisplaySettingsView(viewModel: .init())
        case .alarmSettings: AlarmSettingsView()
        case .apn: APNSettingsView()
        #if !targetEnvironment(macCatalyst)
            case .liveActivity: LiveActivitySettingsView()
        #endif
        case .remote: RemoteSettingsView(viewModel: .init())
        case .importExport: ImportExportSettingsView()
        case .calendar: CalendarSettingsView()
        case .contact: ContactSettingsView(viewModel: .init())
        case .advanced: AdvancedSettingsView(viewModel: .init())
        case .aggregatedStats:
            AggregatedStatsViewWrapper()
        }
    }
}

// Helper view to access MainViewController
struct AggregatedStatsViewWrapper: View {
    @State private var mainViewController: MainViewController?

    var body: some View {
        Group {
            if let mainVC = mainViewController {
                AggregatedStatsContentView(mainViewController: mainVC)
            } else {
                Text("Loading stats...")
                    .onAppear {
                        mainViewController = getMainViewController()
                    }
            }
        }
    }

    private func getMainViewController() -> MainViewController? {
        MainViewController.shared
    }
}

// MARK: – UIKit helpers (unchanged)

extension UIApplication {
    var topMost: UIViewController? {
        // `keyWindow` is deprecated and returns nil on Mac Catalyst / multi-window iPad.
        // Walk connected scenes instead and prefer the foreground-active one.
        let windowScenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first { $0.activationState == .foregroundActive }
            ?? windowScenes.first
        let rootVC = activeScene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? activeScene?.windows.first?.rootViewController
        guard var top = rootVC else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

extension UIViewController {
    func presentSimpleAlert(title: String, message: String) {
        let a = UIAlertController(title: title,
                                  message: message,
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(a, animated: true)
    }
}
