// LoopFollow
// WidgetKinds.swift

import Foundation

/// WidgetKit kind identifiers.
///
/// Lives in Shared because the app needs the identifier to request reloads while
/// the widget itself is declared in the extension target. The raw strings are part
/// of the installed widget's identity — changing one drops the widget the user has
/// already placed on their lock screen.
enum WidgetKinds {
    static let lockScreen = "LoopFollowLockScreenWidget"
}
