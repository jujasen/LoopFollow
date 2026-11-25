// LoopFollow
// MainHomeView.swift

import SwiftUI

/// Home, laid out like Loop's status screen: the HUD on top, four numbers,
/// the cards that come and go (sent commands, low watch, AI suggestions), the
/// chart, and the statistics in plain words.
struct MainHomeView: View {
    // Deliberately not @ObservedObject: this view only passes the model on.
    // The chart views observe what they each need, so data and (especially)
    // per-frame pan/zoom updates don't re-evaluate this whole screen.
    let chartModel: BGChartModel
    @ObservedObject var infoManager: InfoManager
    @ObservedObject var statsModel: StatsDisplayModel

    @ObservedObject var showSmallGraph = Storage.shared.showSmallGraph
    @ObservedObject var showStats = Storage.shared.showStats
    @ObservedObject var hideInfoTable = Storage.shared.hideInfoTable
    @ObservedObject var infoTableOnHome = Storage.shared.infoTableOnHome
    @ObservedObject var showDeviceStatus = Storage.shared.showDeviceStatus
    @ObservedObject var smallGraphHeight = Storage.shared.smallGraphHeight
    @ObservedObject var url = Storage.shared.url
    @ObservedObject var graphTimeZoneEnabled = Storage.shared.graphTimeZoneEnabled
    @ObservedObject var graphTimeZoneIdentifier = Storage.shared.graphTimeZoneIdentifier
    @ObservedObject var serverText = Observable.shared.serverText
    @ObservedObject var showDisplayName = Storage.shared.showDisplayName

    var onRefresh: (() -> Void)?
    var onStatsTap: (() -> Void)?

    private var timeZoneOverride: String? {
        guard graphTimeZoneEnabled.value,
              let tz = TimeZone(identifier: graphTimeZoneIdentifier.value)
        else { return nil }
        return tz.identifier
    }

    private var isNightscoutEnabled: Bool {
        !url.value.isEmpty
    }

    var body: some View {
        // No spacing of its own: the cards that come and go carry their own gap,
        // so they leave none behind while they are away.
        VStack(spacing: 0) {
            // The name to follow, when «Show Display Name» is on (otherwise it only says «Nightscout»)
            if showDisplayName.value, !serverText.value.isEmpty {
                Text(serverText.value)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }

            // Loop-style HUD: loop ring, glucose, pod and sensor
            HomeHUDCard(
                infoManager: infoManager,
                showsLoop: isNightscoutEnabled,
                showsDevices: isNightscoutEnabled && showDeviceStatus.value,
                onRefresh: onRefresh
            )
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.bottom, 8)

            if isNightscoutEnabled {
                // Active insulin, active carbs, basal and the forecast
                HomeNumbersCard(
                    infoManager: infoManager,
                    opensInfoTable: !hideInfoTable.value && !infoTableOnHome.value,
                    timeZoneOverride: timeZoneOverride
                )
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.bottom, 8)

                // The full information table, for those who keep it on Home
                if !hideInfoTable.value && infoTableOnHome.value {
                    HomeInfoTableCard(infoManager: infoManager, timeZoneOverride: timeZoneOverride)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .padding(.bottom, 8)
                }

                // Remote commands sent from here, until Loop has said what became of them
                RemoteCommandCard()
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)

                // Loop's low watch: fast carbs before a low
                LowWatchCard()
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)

                // Loop's AI bolus suggestions, with a button that opens the bolus screen filled in
                AIBolusSuggestionCard()
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }

            // The chart (fills the remaining space), with the small overview chart under it
            HomeChartCard(
                chartModel: chartModel,
                showsSmallGraph: showSmallGraph.value,
                smallGraphHeight: CGFloat(smallGraphHeight.value)
            )
            .padding(.bottom, showStats.value ? 8 : 0)

            // Statistics in plain words; the full statistics are a tap away
            if showStats.value {
                HomeStatsCard(model: statsModel, onTap: onStatsTap)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }
}
