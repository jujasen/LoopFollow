// LoopFollow
// HomeHUDCard.swift

import SwiftUI

/// The top of Home, laid out like the HUD at the top of Loop's status screen:
/// the loop ring with its age, and the glucose with trend, delta and age in
/// large type. The sensor and pod have their own tiles under it.
/// Pull down on it to refresh, as before.
/// While the chart is being scrubbed it shows the scrubbed time instead.
struct HomeHUDCard: View {
    @ObservedObject var infoManager: InfoManager
    /// Nightscout is set up, so there is a loop to show.
    var showsLoop: Bool
    var onRefresh: (() -> Void)?

    @ObservedObject private var bgText = Observable.shared.bgText
    @ObservedObject private var bgTextColor = Observable.shared.bgTextColor
    @ObservedObject private var bgStale = Observable.shared.bgStale
    @ObservedObject private var directionText = Observable.shared.directionText
    @ObservedObject private var deltaText = Observable.shared.deltaText
    @ObservedObject private var minAgoText = Observable.shared.minAgoText
    @ObservedObject private var loopStatusText = Observable.shared.loopStatusText
    @ObservedObject private var isNotLooping = Observable.shared.isNotLooping
    @ObservedObject private var cgmSensorState = Observable.shared.cgmSensorState
    @ObservedObject private var lastLoopTime = Observable.shared.alertLastLoopTime
    @ObservedObject private var retro = RetroSelection.shared

    var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 12) {
                if showsLoop {
                    loopColumn
                }
                glucoseColumn
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .refreshable { onRefresh?() }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            if retro.snapshot != nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(RetroSnapshot.accent.opacity(0.18))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Loop ring

    private var loopColumn: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let lastLoop = (lastLoopTime.value ?? 0) > 0 ? Date(timeIntervalSince1970: lastLoopTime.value ?? 0) : nil
            let freshness = ringFreshness(lastLoop: lastLoop, now: context.date)
            VStack(spacing: 4) {
                LoopRingView(freshness: freshness, isOpenLoop: loopStatusText.value == "⏀")
                    .frame(width: 38, height: 38)
                Text(LoopFreshness.ageText(lastLoop: lastLoop, now: context.date))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(freshness == .stale ? Color.red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 48)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loopAccessibilityLabel(lastLoop: lastLoop, now: context.date))
        }
    }

    /// A failed last run never reads as fresh, the way Loop's ring only counts completed runs.
    private func ringFreshness(lastLoop: Date?, now: Date) -> LoopFreshness {
        let freshness = LoopFreshness(lastLoop: lastLoop, now: now)
        if loopStatusText.value == "X", freshness == .fresh {
            return .aging
        }
        return freshness
    }

    private func loopAccessibilityLabel(lastLoop: Date?, now: Date) -> String {
        guard lastLoop != nil else {
            return String(localized: "Loop: no runs seen yet", table: "Home")
        }
        return String(format: String(localized: "Loop ran %@ ago", table: "Home", comment: "1: e.g. 2 min"), LoopFreshness.ageText(lastLoop: lastLoop, now: now))
    }

    // MARK: Glucose

    private var glucoseColumn: some View {
        let snapshot = retro.snapshot
        let isStale = snapshot == nil && bgStale.value
        let unit = UnitSettingsStore.shared.glucoseUnit.rawValue
        let delta = snapshot?.deltaText ?? deltaText.value
        let detail = snapshot == nil
            ? [unit, minAgoText.value].filter { !$0.isEmpty }.joined(separator: " · ")
            : unit

        return VStack(alignment: .center, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Text(snapshot?.bgText ?? bgText.value)
                    .font(.system(size: 84, weight: .black))
                    .monospacedDigit()
                    .foregroundStyle(Self.readable(snapshot?.bgColor ?? bgTextColor.value))
                    .strikethrough(isStale, pattern: .solid, color: .red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                VStack(alignment: .leading, spacing: -4) {
                    Text(snapshot?.directionText ?? directionText.value)
                        .font(.system(size: 50, weight: .black))
                    if !delta.isEmpty {
                        Text(delta)
                            .font(.system(size: 30, weight: .bold))
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
            Text(detail)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let snapshot {
                Label(snapshot.timeText, systemImage: "clock.arrow.circlepath")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(RetroSnapshot.accent.opacity(0.3)))
                    .padding(.top, 2)
            } else {
                if let state = cgmSensorState.value {
                    Text("CGM: \(state.summary)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HomePalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsLoop, isNotLooping.value {
                    Text(loopStatusText.value)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The BG colours from «Color BG Text», with yellow darkened so it can be read on white.
    private static func readable(_ color: Color) -> Color {
        color == .yellow ? HomePalette.highGlucose : color
    }
}

extension HomePalette {
    static let highGlucose = Color(UIColor {
        $0.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.72, green: 0.53, blue: 0.00, alpha: 1)
    })
}
