// LoopFollow
// LoopFollowChartView.swift

import Charts
import SwiftUI

/// The glucose plot used by the "Plot and Row" Live Activity layout.
///
/// Past readings are drawn as a solid line, the prediction as a dashed one, over a
/// shaded band marking the user's own low/high lines. The Live Activity renders on
/// a tinted card, so everything here is drawn in white at varying opacity rather
/// than in semantic colours — the card's tint already carries the in-range signal.
struct LoopFollowChartView: View {
    let series: GlucoseChartSeries
    let unit: GlucoseSnapshot.Unit

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    var body: some View {
        Chart {
            // Target band first so the lines draw over it.
            RectangleMark(
                yStart: .value("Low", display(thresholds.low)),
                yEnd: .value("High", display(thresholds.high)),
            )
            .foregroundStyle(.white.opacity(0.14))

            ForEach(historyPoints) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Glucose", point.value),
                    series: .value("Series", "history"),
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(.white)
            }

            ForEach(predictionPoints) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Glucose", point.value),
                    series: .value("Series", "prediction"),
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .foregroundStyle(.white.opacity(0.55))
            }

            // Marks "now" where the reading ends and the prediction begins.
            if let last = historyPoints.last {
                PointMark(
                    x: .value("Time", last.date),
                    y: .value("Glucose", last.value),
                )
                .symbolSize(38)
                .foregroundStyle(.white)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.18))
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: yAxisValues) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(axisLabel(v))
                            .foregroundStyle(.white.opacity(0.6))
                            .font(.system(size: 9))
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var historyPoints: [Point] {
        series.historyPoints.map { Point(date: $0.date, value: display($0.mgdl)) }
    }

    private var predictionPoints: [Point] {
        // Start the dashed line at the last reading so the two lines join up
        // instead of leaving a visual gap across "now".
        let predicted = series.predictionPoints.map { Point(date: $0.date, value: display($0.mgdl)) }
        guard let last = series.historyPoints.last, !predicted.isEmpty else { return predicted }
        return [Point(date: last.date, value: display(last.mgdl))] + predicted
    }

    private var thresholds: (low: Double, high: Double) {
        LAAppGroupSettings.thresholdsMgdl()
    }

    /// Converts mg/dL into whatever unit the user reads.
    private func display(_ mgdl: Double) -> Double {
        switch unit {
        case .mgdl: mgdl
        case .mmol: GlucoseConversion.toMmol(mgdl)
        }
    }

    /// Y range covering the data and the target band, with a little headroom so
    /// lines never touch the frame.
    private var yDomain: ClosedRange<Double> {
        let values = historyPoints.map(\.value) + predictionPoints.map(\.value)
        let padding = display(20) - display(0)
        let lowCandidates = values + [display(thresholds.low)]
        let highCandidates = values + [display(thresholds.high)]

        let lower = (lowCandidates.min() ?? display(70)) - padding
        let upper = (highCandidates.max() ?? display(180)) + padding
        guard upper > lower else { return display(40) ... display(300) }
        return lower ... upper
    }

    /// Three labels — enough to read the scale without crowding a card this small.
    private var yAxisValues: [Double] {
        let d = yDomain
        let step = (d.upperBound - d.lowerBound) / 4
        return [d.lowerBound + step, d.lowerBound + 2 * step, d.lowerBound + 3 * step]
    }

    private func axisLabel(_ value: Double) -> String {
        switch unit {
        case .mgdl: String(Int(value.rounded()))
        case .mmol: String(format: "%.0f", value)
        }
    }
}
