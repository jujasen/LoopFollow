// LoopFollow
// HomeChartCard.swift

import SwiftUI

/// The glucose chart in a card, with a 3/6/12/24 h control above it. The chart
/// itself is unchanged: pinch, pan, scrub and taps work as before.
struct HomeChartCard: View {
    let chartModel: BGChartModel
    var showsSmallGraph: Bool
    var smallGraphHeight: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(String(localized: "Glucose", table: "Home", comment: "Title of the chart card on Home"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ChartSpanControl(model: chartModel, interaction: chartModel.interaction)
            }
            .padding(.horizontal, 4)

            BGChartView(model: chartModel, config: .main)

            if showsSmallGraph {
                BGChartView(model: chartModel, config: .small)
                    .frame(height: smallGraphHeight)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// A compact segmented control for the chart's span. No segment is chosen
/// when a pinch has left the chart between two of them.
struct ChartSpanControl: View {
    let model: BGChartModel
    @ObservedObject var interaction: BGChartInteraction

    var body: some View {
        let selected = ChartSpan.matching(visibleSeconds: interaction.visibleSeconds)
        HStack(spacing: 2) {
            ForEach(ChartSpan.allCases) { span in
                let isSelected = span == selected
                Button {
                    interaction.show(seconds: span.rawValue, model: model)
                } label: {
                    Text(span.label)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(HomePalette.selectedSegment)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(String(format: String(localized: "%lld hours", table: "Home", comment: "Chart span, for VoiceOver"), span.hours))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemFill)))
    }
}
