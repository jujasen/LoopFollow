// LoopFollow
// LoopFollowLockScreenWidget.swift

import SwiftUI
import WidgetKit

// MARK: - Timeline entry

/// A single rendered state of the lock screen widget.
///
/// `snapshot` is nil until the app has written its first `GlucoseSnapshot` to the
/// App Group container — typically only before the first Nightscout fetch after
/// install, or if the user has never opened the app.
struct GlucoseWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot?

    /// True when the reading is old enough that it must not be presented as current.
    /// Compared against the entry date rather than `Date()` so that future timeline
    /// entries evaluate staleness at the moment they are actually displayed.
    var isStale: Bool {
        guard let snapshot else { return true }
        return date.timeIntervalSince(snapshot.updatedAt) >= WidgetFormat.staleAfter
    }
}

// MARK: - Timeline provider

/// Supplies entries from the App Group snapshot written by `GlucoseSnapshotStore`.
///
/// The widget never fetches on its own: the extension has no Nightscout credentials
/// and no background budget worth relying on. Fresh data arrives because the app
/// calls `WidgetCenter.reloadTimelines` whenever it stores a new snapshot. The
/// entries generated here exist only so the widget can age *itself* correctly if
/// the app goes quiet — otherwise a reading from hours ago would keep rendering as
/// though it had just arrived.
struct GlucoseWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> GlucoseWidgetEntry {
        GlucoseWidgetEntry(date: Date(), snapshot: WidgetPreviewData.snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseWidgetEntry) -> Void) {
        // The widget gallery has no App Group data worth showing, so preview with
        // representative values instead of an empty placeholder.
        let snapshot = context.isPreview
            ? WidgetPreviewData.snapshot
            : GlucoseSnapshotStore.shared.load()
        completion(GlucoseWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlucoseWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = GlucoseSnapshotStore.shared.load()
        var entries = [GlucoseWidgetEntry(date: now, snapshot: snapshot)]

        // Re-render exactly when the current reading goes stale, so the widget
        // switches to its stale presentation on time rather than at the next
        // arbitrary refresh.
        if let snapshot {
            let staleAt = snapshot.updatedAt.addingTimeInterval(WidgetFormat.staleAfter)
            if staleAt > now {
                entries.append(GlucoseWidgetEntry(date: staleAt, snapshot: snapshot))
            }
        }

        // Hourly backstop entries. These matter only when the app has stopped
        // reloading us entirely; WidgetKit reloads at the end of the timeline.
        for hour in 1 ... 4 {
            entries.append(
                GlucoseWidgetEntry(date: now.addingTimeInterval(Double(hour) * 3600), snapshot: snapshot),
            )
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Widget

struct LoopFollowLockScreenWidget: Widget {
    static let kind = WidgetKinds.lockScreen

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseWidgetProvider()) { entry in
            LockScreenWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Glucose")
        .description("Latest glucose reading, trend and loop status.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Family router

private struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularView(entry: entry)
        case .accessoryRectangular:
            RectangularView(entry: entry)
        case .accessoryInline:
            InlineView(entry: entry)
        default:
            // Not reachable given supportedFamilies, but WidgetFamily is not
            // exhaustive across OS versions.
            InlineView(entry: entry)
        }
    }
}

// MARK: - Circular

/// Glucose value inside a gauge ring positioned against the user's own low/high
/// lines. On the lock screen accessory widgets render monochrome, so the ring —
/// not colour — is what communicates how far from range the reading is.
private struct CircularView: View {
    let entry: GlucoseWidgetEntry

    var body: some View {
        Gauge(value: gaugePosition, in: 0 ... 1) {
            EmptyView()
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text(valueText)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(arrowText)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
        }
        .gaugeStyle(.accessoryCircular)
        .opacity(entry.isStale ? 0.55 : 1)
        .widgetAccentable()
    }

    private var valueText: String {
        guard let snapshot = entry.snapshot else { return "—" }
        return LAFormat.glucose(snapshot)
    }

    private var arrowText: String {
        guard let snapshot = entry.snapshot else { return "" }
        return entry.isStale ? WidgetFormat.staleMarker : LAFormat.trendArrow(snapshot)
    }

    /// Position of the reading on the ring, 0...1, anchored to the user's
    /// thresholds so the ring means the same thing as the app's low/high lines.
    private var gaugePosition: Double {
        guard let snapshot = entry.snapshot else { return 0 }
        let t = LAAppGroupSettings.thresholdsMgdl()
        let lower = max(0, t.low - 30)
        let upper = t.high + 60
        guard upper > lower else { return 0 }
        return min(max((snapshot.glucose - lower) / (upper - lower), 0), 1)
    }
}

// MARK: - Rectangular

/// Three-line layout: glucose with trend and delta, the two metrics a follower
/// checks next (IOB/COB), and how old the reading is.
private struct RectangularView: View {
    let entry: GlucoseWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valueText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .widgetAccentable()
                Text(trendText)
                    .font(.system(size: 13, weight: .medium))
                if let snapshot = entry.snapshot, snapshot.isNotLooping {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Text(metricsText)
                .font(.system(size: 12))
                .lineLimit(1)

            Text(ageText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(entry.isStale ? 0.6 : 1)
    }

    private var valueText: String {
        guard let snapshot = entry.snapshot else { return "—" }
        return LAFormat.glucose(snapshot)
    }

    private var trendText: String {
        guard let snapshot = entry.snapshot else { return "" }
        if entry.isStale { return WidgetFormat.staleMarker }
        return "\(LAFormat.trendArrow(snapshot))  \(LAFormat.delta(snapshot))"
    }

    private var metricsText: String {
        guard let snapshot = entry.snapshot else { return "Open LoopFollow to sync" }
        return "IOB \(LAFormat.iob(snapshot))   COB \(LAFormat.cob(snapshot))"
    }

    private var ageText: String {
        guard let snapshot = entry.snapshot else { return "No data" }
        return WidgetFormat.age(of: snapshot.updatedAt, at: entry.date)
    }
}

// MARK: - Inline

/// A single line above the lock screen clock. Inline accessories allow only one
/// text run, so this stays to value, trend and delta.
private struct InlineView: View {
    let entry: GlucoseWidgetEntry

    var body: some View {
        Text(text)
    }

    private var text: String {
        guard let snapshot = entry.snapshot else { return "LoopFollow —" }
        if entry.isStale {
            return "\(LAFormat.glucose(snapshot)) \(WidgetFormat.staleMarker) \(WidgetFormat.age(of: snapshot.updatedAt, at: entry.date))"
        }
        return "\(LAFormat.glucose(snapshot)) \(LAFormat.trendArrow(snapshot)) \(LAFormat.delta(snapshot))"
    }
}

// MARK: - Widget-specific formatting

enum WidgetFormat {
    /// A CGM reports every five minutes. Two missed readings is the point where a
    /// value stops being trustworthy at a glance, so the widget stops presenting
    /// it as current.
    static let staleAfter: TimeInterval = 12 * 60

    /// Shown in place of the trend arrow once a reading is stale — a trend derived
    /// from old data is worse than no trend at all.
    static let staleMarker = "⚠︎"

    private static let ageFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        f.maximumUnitCount = 1
        return f
    }()

    /// Age of a reading as seen from `referenceDate`, e.g. "3 min ago".
    static func age(of updatedAt: Date, at referenceDate: Date) -> String {
        let seconds = max(0, referenceDate.timeIntervalSince(updatedAt))
        if seconds < 60 { return "just now" }
        guard let formatted = ageFormatter.string(from: seconds) else { return "" }
        return "\(formatted) ago"
    }
}

// MARK: - Preview data

private enum WidgetPreviewData {
    /// Representative values for the widget gallery and Xcode previews.
    static let snapshot = GlucoseSnapshot(
        glucose: 118,
        delta: 4,
        trend: .upSlight,
        updatedAt: Date(),
        iob: 0.35,
        cob: 12,
        projected: 126,
        unit: .mmol,
        isNotLooping: false,
    )
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    LoopFollowLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: Date(), snapshot: WidgetPreviewData.snapshot)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LoopFollowLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: Date(), snapshot: WidgetPreviewData.snapshot)
}

#Preview("Inline", as: .accessoryInline) {
    LoopFollowLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: Date(), snapshot: WidgetPreviewData.snapshot)
}
