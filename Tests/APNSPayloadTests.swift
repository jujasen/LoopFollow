// LoopFollow
// APNSPayloadTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// `APNSClient` builds the Live Activity `content-state` by hand, while everything
/// else in the pipeline goes through Codable. The two can drift: a field added to
/// `GlucoseSnapshot` keeps working in the foreground, where ActivityKit is handed a
/// Codable value directly, and silently vanishes from every background push.
///
/// These tests pin the two representations together.
struct APNSPayloadTests {
    private static let base = Date(timeIntervalSince1970: 1_756_377_600)

    private static func chart() -> GlucoseChartSeries? {
        GlucoseChartSeries.build(
            history: stride(from: 0.0, through: 2 * 3600, by: 300).map {
                (date: base.timeIntervalSince1970 - $0, mgdl: 100 + 30 * sin($0 / 900))
            },
            prediction: stride(from: 300.0, through: 2 * 3600, by: 300).map {
                (date: base.timeIntervalSince1970 + $0, mgdl: 120 + 20 * cos($0 / 1200))
            },
            baseDate: base,
        )
    }

    /// Every optional populated, so a missing key in the hand-built dictionary shows up.
    private static func fullSnapshot() -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: 118.4,
            delta: -4.2,
            trend: .downSlight,
            updatedAt: base,
            iob: 1.35,
            cob: 42,
            projected: 126.7,
            override: "Exercise",
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
            profileName: "Weekday",
            sageInsertTime: base.timeIntervalSince1970 - 200_000,
            cageInsertTime: base.timeIntervalSince1970 - 100_000,
            iageInsertTime: base.timeIntervalSince1970 - 150_000,
            minBgMgdl: 78,
            maxBgMgdl: 210,
            unit: .mmol,
            isNotLooping: false,
            showRenewalOverlay: false,
            chart: chart(),
        )
    }

    private static func contentState() -> GlucoseLiveActivityAttributes.ContentState {
        GlucoseLiveActivityAttributes.ContentState(
            snapshot: fullSnapshot(),
            seq: 7,
            reason: "test",
            producedAt: base,
        )
    }

    /// The guard that matters: the push payload must carry every field Codable does.
    @Test("hand-built push payload carries every snapshot field the Codable encoding does")
    func payloadCoversAllCodableKeys() throws {
        let dict = try #require(APNSClient.shared.contentStateDictionary(state: Self.contentState()))
        let pushKeys = try Set(#require(dict["snapshot"] as? [String: Any]).keys)

        let encoded = try JSONEncoder().encode(Self.fullSnapshot())
        let codableKeys = try Set(#require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        ).keys)

        let missing = codableKeys.subtracting(pushKeys)
        #expect(missing.isEmpty, "fields missing from the APNs push payload: \(missing.sorted())")
    }

    /// A push payload must decode back into the same snapshot the app built, or the
    /// card renders something different from what the app intended.
    @Test("push payload decodes back into an equivalent content state")
    func payloadRoundTripsIntoContentState() throws {
        let dict = try #require(APNSClient.shared.contentStateDictionary(state: Self.contentState()))
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(GlucoseLiveActivityAttributes.ContentState.self, from: data)

        #expect(decoded.snapshot == Self.fullSnapshot())
    }

    /// The specific regression: the chart survived the foreground path but was
    /// dropped from background pushes, so the card fell back to the grid layout.
    @Test("chart series survives the push payload intact")
    func chartSurvivesPushPayload() throws {
        let dict = try #require(APNSClient.shared.contentStateDictionary(state: Self.contentState()))
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(GlucoseLiveActivityAttributes.ContentState.self, from: data)

        let chart = try #require(decoded.snapshot.chart)
        #expect(chart == Self.chart())
        #expect(!chart.historyMinutes.isEmpty)
        #expect(!chart.predictionMinutes.isEmpty)
    }

    /// APNs rejects a Live Activity payload over 4 KB, and that ceiling covers the
    /// whole envelope, not just the content state.
    @Test("full push payload stays under the APNs 4 KB limit")
    func fullPayloadFitsApnsLimit() throws {
        let dict = try #require(APNSClient.shared.contentStateDictionary(state: Self.contentState()))
        let payload: [String: Any] = [
            "aps": [
                "timestamp": Int(Self.base.timeIntervalSince1970),
                "event": "update",
                "content-state": dict,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(data.count < 4096, "APNs payload was \(data.count) bytes")
    }
}
