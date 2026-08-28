// LoopFollow
// GlucoseChartSeriesTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct GlucoseChartSeriesTests {
    // MARK: - Helpers

    private static let base = Date(timeIntervalSince1970: 1_756_377_600)

    /// A CGM reporting every five minutes for `hours` back from the base date.
    private static func denseHistory(hours: Double) -> [(date: TimeInterval, mgdl: Double)] {
        let baseSeconds = base.timeIntervalSince1970
        return stride(from: 0.0, through: hours * 3600, by: 300).map {
            (date: baseSeconds - $0, mgdl: 100 + 40 * sin($0 / 900))
        }
    }

    private static func densePrediction(hours: Double) -> [(date: TimeInterval, mgdl: Double)] {
        let baseSeconds = base.timeIntervalSince1970
        return stride(from: 300.0, through: hours * 3600, by: 300).map {
            (date: baseSeconds + $0, mgdl: 120 + 30 * cos($0 / 1200))
        }
    }

    /// Worst case for payload size: every optional populated and a full chart.
    private static func fullSnapshot(chart: GlucoseChartSeries?) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: 118.4,
            delta: -4.2,
            trend: .downSlight,
            updatedAt: base,
            iob: 1.35,
            cob: 42,
            projected: 126.7,
            override: "Exercise preset with a long name",
            overrideEndAt: base.timeIntervalSince1970 + 3600,
            tempTargetMgdl: 140,
            tempTargetEndAt: base.timeIntervalSince1970 + 1800,
            recBolus: 0.85,
            battery: 88,
            pumpBattery: 74,
            basalRate: "0.45 U/hr",
            pumpReservoirU: 32.5,
            autosens: 0.92,
            tdd: 18.4,
            targetLowMgdl: 90,
            targetHighMgdl: 140,
            isfMgdlPerU: 180,
            carbRatio: 22.5,
            carbsToday: 145,
            profileName: "Weekday profile",
            sageInsertTime: base.timeIntervalSince1970 - 200_000,
            cageInsertTime: base.timeIntervalSince1970 - 100_000,
            iageInsertTime: base.timeIntervalSince1970 - 150_000,
            minBgMgdl: 78,
            maxBgMgdl: 210,
            unit: .mmol,
            isNotLooping: false,
            showRenewalOverlay: false,
            chart: chart,
        )
    }

    // MARK: - Payload size

    /// ActivityKit rejects a ContentState over 4 KB. The chart series is the only
    /// unbounded-looking part of the snapshot, so this guards the whole payload
    /// against a future change that widens the windows or the encoding.
    @Test("fully populated snapshot with a full chart stays under ActivityKit's 4 KB limit")
    func payloadFitsContentStateLimit() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 6),
                prediction: Self.densePrediction(hours: 6),
                baseDate: Self.base,
            ),
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Self.fullSnapshot(chart: chart))

        #expect(data.count < 4096, "snapshot payload was \(data.count) bytes")
    }

    @Test("the chart series itself stays compact")
    func seriesEncodingIsCompact() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 6),
                prediction: Self.densePrediction(hours: 6),
                baseDate: Self.base,
            ),
        )

        let data = try JSONEncoder().encode(chart)
        #expect(data.count < 1024, "series payload was \(data.count) bytes")
    }

    // MARK: - Windowing and downsampling

    @Test("history is clipped to its window and point cap")
    func historyIsCapped() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 12),
                prediction: [],
                baseDate: Self.base,
            ),
        )

        #expect(chart.historyMinutes.count <= GlucoseChartSeries.maxHistoryPoints)
        #expect(chart.historyMgdl.count == chart.historyMinutes.count)

        let oldest = try #require(chart.historyMinutes.min())
        #expect(Double(-oldest) * 60 <= GlucoseChartSeries.historyWindow)
    }

    @Test("prediction is clipped to its window even when more is loaded")
    func predictionIsCapped() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: [],
                prediction: Self.densePrediction(hours: 12),
                baseDate: Self.base,
            ),
        )

        #expect(chart.predictionMinutes.count <= GlucoseChartSeries.maxPredictionPoints)
        let furthest = try #require(chart.predictionMinutes.max())
        #expect(Double(furthest) * 60 <= GlucoseChartSeries.predictionWindow)
    }

    /// The newest reading is what the card's number refers to — thinning must never
    /// drop it, or the plot would end before the value it is drawn next to.
    @Test("downsampling keeps the newest reading")
    func downsamplingKeepsNewestPoint() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 6),
                prediction: [],
                baseDate: Self.base,
            ),
        )

        #expect(chart.historyMinutes.last == 0)
    }

    @Test("points stay in ascending time order")
    func pointsAreOrdered() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 2).shuffled(),
                prediction: Self.densePrediction(hours: 2).shuffled(),
                baseDate: Self.base,
            ),
        )

        #expect(chart.historyMinutes == chart.historyMinutes.sorted())
        #expect(chart.predictionMinutes == chart.predictionMinutes.sorted())
    }

    // MARK: - Empty cases

    @Test("no usable samples produces no series")
    func emptyInputProducesNil() {
        #expect(GlucoseChartSeries.build(history: [], prediction: [], baseDate: Self.base) == nil)
    }

    /// Readings far in the past are all that a stale follower has; they must not
    /// produce a chart that looks current.
    @Test("samples outside the window produce no series")
    func staleInputProducesNil() {
        let ancient = Self.denseHistory(hours: 12).filter {
            $0.date < Self.base.timeIntervalSince1970 - GlucoseChartSeries.historyWindow
        }
        #expect(GlucoseChartSeries.build(history: ancient, prediction: [], baseDate: Self.base) == nil)
    }

    // MARK: - Round trip

    @Test("encoding round-trips without losing points")
    func roundTrips() throws {
        let chart = try #require(
            GlucoseChartSeries.build(
                history: Self.denseHistory(hours: 2),
                prediction: Self.densePrediction(hours: 2),
                baseDate: Self.base,
            ),
        )

        let data = try JSONEncoder().encode(chart)
        let decoded = try JSONDecoder().decode(GlucoseChartSeries.self, from: data)

        #expect(decoded == chart)
    }

    /// Snapshots written by an older build have no chart key at all.
    @Test("snapshot without a chart key still decodes")
    func snapshotDecodesWithoutChart() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Self.fullSnapshot(chart: nil))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GlucoseSnapshot.self, from: data)

        #expect(decoded.chart == nil)
        #expect(decoded.glucose == 118.4)
    }
}
