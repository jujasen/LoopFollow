// LoopFollow
// GlucoseChartSeries.swift

import Foundation

/// Recent and predicted glucose, shaped for the Live Activity chart.
///
/// This travels inside the Live Activity's ContentState, which ActivityKit caps at
/// 4 KB — the whole `GlucoseSnapshot` has to fit in that budget too. So the points
/// are not stored as an array of structs with ISO dates (roughly 40 bytes each) but
/// as parallel arrays of integers: minute offsets from a single base date, and
/// glucose rounded to whole mg/dL. That keeps a full series near 600 bytes instead
/// of several kilobytes.
///
/// Offsets are used rather than a fixed interval because real CGM data has gaps —
/// a dropped reading must shift the remaining points, not silently retime them.
struct GlucoseChartSeries: Codable, Equatable, Hashable {
    /// All minute offsets are relative to this instant, normally the latest reading.
    let baseDate: Date

    /// Minute offsets of past readings, negative into the past, ascending.
    let historyMinutes: [Int]

    /// Past glucose in mg/dL, index-aligned with `historyMinutes`.
    let historyMgdl: [Int]

    /// Minute offsets of predicted values, positive into the future, ascending.
    let predictionMinutes: [Int]

    /// Predicted glucose in mg/dL, index-aligned with `predictionMinutes`.
    let predictionMgdl: [Int]

    // MARK: - Derived

    /// True when there is nothing worth drawing.
    var isEmpty: Bool {
        historyMinutes.isEmpty && predictionMinutes.isEmpty
    }

    /// Past readings as (date, mg/dL) pairs, dropping any index mismatch.
    var historyPoints: [(date: Date, mgdl: Double)] {
        zip(historyMinutes, historyMgdl).map {
            (baseDate.addingTimeInterval(Double($0.0) * 60), Double($0.1))
        }
    }

    /// Predicted values as (date, mg/dL) pairs.
    var predictionPoints: [(date: Date, mgdl: Double)] {
        zip(predictionMinutes, predictionMgdl).map {
            (baseDate.addingTimeInterval(Double($0.0) * 60), Double($0.1))
        }
    }

    // MARK: - Codable

    /// Short keys, again to stay inside the 4 KB ContentState budget.
    private enum CodingKeys: String, CodingKey {
        case baseDate = "b"
        case historyMinutes = "hm"
        case historyMgdl = "hv"
        case predictionMinutes = "pm"
        case predictionMgdl = "pv"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseDate.timeIntervalSince1970, forKey: .baseDate)
        try container.encode(historyMinutes, forKey: .historyMinutes)
        try container.encode(historyMgdl, forKey: .historyMgdl)
        try container.encode(predictionMinutes, forKey: .predictionMinutes)
        try container.encode(predictionMgdl, forKey: .predictionMgdl)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseDate = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .baseDate))
        historyMinutes = try container.decodeIfPresent([Int].self, forKey: .historyMinutes) ?? []
        historyMgdl = try container.decodeIfPresent([Int].self, forKey: .historyMgdl) ?? []
        predictionMinutes = try container.decodeIfPresent([Int].self, forKey: .predictionMinutes) ?? []
        predictionMgdl = try container.decodeIfPresent([Int].self, forKey: .predictionMgdl) ?? []
    }

    init(
        baseDate: Date,
        historyMinutes: [Int],
        historyMgdl: [Int],
        predictionMinutes: [Int],
        predictionMgdl: [Int],
    ) {
        self.baseDate = baseDate
        self.historyMinutes = historyMinutes
        self.historyMgdl = historyMgdl
        self.predictionMinutes = predictionMinutes
        self.predictionMgdl = predictionMgdl
    }
}

// MARK: - Building

extension GlucoseChartSeries {
    /// How far back the chart looks.
    static let historyWindow: TimeInterval = 2 * 3600

    /// How far forward the chart looks, regardless of how much prediction data
    /// the user has configured LoopFollow to load.
    static let predictionWindow: TimeInterval = 3 * 3600

    /// Hard caps on point count. Reached only if a source delivers denser data than
    /// a CGM's five-minute cadence; the windows above are the practical limit.
    static let maxHistoryPoints = 24
    static let maxPredictionPoints = 36

    /// Builds a series from raw (timestamp, mg/dL) samples.
    ///
    /// - Parameters:
    ///   - history: past readings, any order, epoch seconds.
    ///   - prediction: predicted values, any order, epoch seconds.
    ///   - baseDate: the instant offsets are measured from — normally the latest reading.
    static func build(
        history: [(date: TimeInterval, mgdl: Double)],
        prediction: [(date: TimeInterval, mgdl: Double)],
        baseDate: Date,
    ) -> GlucoseChartSeries? {
        let base = baseDate.timeIntervalSince1970

        let pastCutoff = base - historyWindow
        let past = downsample(
            history
                .filter { $0.date >= pastCutoff && $0.date <= base && $0.mgdl > 0 }
                .sorted { $0.date < $1.date },
            limit: maxHistoryPoints,
        )

        let futureCutoff = base + predictionWindow
        let future = downsample(
            prediction
                .filter { $0.date > base && $0.date <= futureCutoff && $0.mgdl > 0 }
                .sorted { $0.date < $1.date },
            limit: maxPredictionPoints,
        )

        guard !past.isEmpty || !future.isEmpty else { return nil }

        return GlucoseChartSeries(
            baseDate: baseDate,
            historyMinutes: past.map { Int((($0.date - base) / 60).rounded()) },
            historyMgdl: past.map { Int($0.mgdl.rounded()) },
            predictionMinutes: future.map { Int((($0.date - base) / 60).rounded()) },
            predictionMgdl: future.map { Int($0.mgdl.rounded()) },
        )
    }

    /// Evenly thins a sorted series down to `limit` points, always keeping the last
    /// one — on a glucose chart the newest reading and the end of the prediction are
    /// the points that carry meaning, so they must survive thinning.
    private static func downsample(
        _ points: [(date: TimeInterval, mgdl: Double)],
        limit: Int,
    ) -> [(date: TimeInterval, mgdl: Double)] {
        guard points.count > limit, limit > 0 else { return points }

        let stride = Double(points.count - 1) / Double(limit - 1)
        var result: [(date: TimeInterval, mgdl: Double)] = []
        result.reserveCapacity(limit)
        for i in 0 ..< limit {
            result.append(points[Int((Double(i) * stride).rounded())])
        }
        return result
    }
}
