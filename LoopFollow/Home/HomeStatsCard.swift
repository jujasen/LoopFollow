// LoopFollow
// HomeStatsCard.swift

import SwiftUI

/// Statistics in plain words: how much of the day was in range, a bar with
/// low / in range / high, and how long each lasted. Tapping opens the full
/// statistics, where average, A1C, SD and the rest live.
struct HomeStatsCard: View {
    @ObservedObject var model: StatsDisplayModel
    var onTap: (() -> Void)?

    private static let lowColor = Color.red
    private static let inRangeColor = Color.green
    private static let highColor = Color.yellow

    var body: some View {
        let summary = model.timeInRangeSummary
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.headline())
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(String(localized: "More", table: "Home", comment: "Opens the full statistics from Home"))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }

            DistributionBar(segments: segments(summary))
                .frame(height: 8)

            HStack(alignment: .top, spacing: 8) {
                legend(String(localized: "Low", table: "Home", comment: "Statistics card: below range"), summary.low, summary.hasData, Self.lowColor, alignment: .leading)
                legend(String(localized: "In range", table: "Home", comment: "Statistics card: in range"), summary.inRange, summary.hasData, Self.inRangeColor, alignment: .center)
                legend(String(localized: "High", table: "Home", comment: "Statistics card: above range"), summary.high, summary.hasData, Self.highColor, alignment: .trailing)
            }
        }
        .homeCard(padding: 12)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func segments(_ summary: TimeInRangeSummary) -> [(color: Color, fraction: CGFloat)] {
        guard summary.hasData else { return [(Color.secondary.opacity(0.3), 1)] }
        return [
            (Self.lowColor, CGFloat(summary.low.percent / 100)),
            (Self.inRangeColor, CGFloat(summary.inRange.percent / 100)),
            (Self.highColor, CGFloat(summary.high.percent / 100)),
        ]
    }

    private func legend(_ name: String, _ band: TimeInRangeSummary.Band, _ hasData: Bool, _ color: Color, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
        return VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name + " " + (hasData ? TimeInRangeSummary.percentText(band.percent) : "–"))
                    .font(.caption.weight(.medium))
            }
            Text(TimeInRangeSummary.durationText(band, hasData: hasData))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// Horizontal bar of capsules, one per non-empty segment, sized by share.
/// Every non-empty segment is at least `minSegmentWidth` wide so a single
/// reading stays visible.
struct DistributionBar: View {
    let segments: [(color: Color, fraction: CGFloat)]

    private let spacing: CGFloat = 2
    private let minSegmentWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let shown = segments.filter { $0.fraction > 0 }
            let available = max(geo.size.width - spacing * CGFloat(max(shown.count - 1, 0)), 0)
            let widths = segmentWidths(shown.map(\.fraction), available: available)
            HStack(spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: widths[index])
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func segmentWidths(_ fractions: [CGFloat], available: CGFloat) -> [CGFloat] {
        var widths = fractions.map { max($0 * available, minSegmentWidth) }
        let excess = widths.reduce(0, +) - available
        if excess > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(widths[widest] - excess, minSegmentWidth)
        }
        return widths
    }
}
