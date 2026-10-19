// LoopFollow
// PumpDeliveryCheck.swift

import Foundation

/// Looks for the sign of insulin that the pump reports as delivered but that never
/// reaches the body — a kinked cannula, a leak or a partial occlusion the pod does
/// not alarm for. The pattern: glucose high and not falling, although the insulin
/// given over the last 90 minutes should by now have pulled it well down.
///
/// The insulin and carb effects use the same shapes as Loop (exponential insulin
/// curve, net basal against the scheduled rate, carbs absorbed evenly over their
/// absorption time), but none of Loop's corrections, so a rise Loop has started to
/// explain away still shows here as unexplained.
///
/// All glucose values are mg/dL.
struct PumpDeliveryCheck: Codable {
    struct Dose: Codable {
        let start: Date
        let end: Date
        /// For basal: delivered minus scheduled, so it can be negative.
        let units: Double
    }

    struct Carb: Codable {
        let date: Date
        let grams: Double
        let absorption: TimeInterval
    }

    /// A daily schedule, values in effect from `secondsFromMidnight` in `timeZone`.
    struct Schedule: Codable {
        let items: [Item]
        let timeZone: TimeZone

        struct Item: Codable {
            let secondsFromMidnight: Int
            let value: Double
        }

        func value(at date: Date) -> Double? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
            return items.last(where: { $0.secondsFromMidnight <= seconds })?.value ?? items.first?.value
        }
    }

    /// Loop's exponential insulin model.
    struct InsulinCurve: Codable, Equatable {
        var peak: TimeInterval = 55 * 60
        var duration: TimeInterval = 6 * 3600
        var delay: TimeInterval = 10 * 60

        /// Loop's presets by `insulinModel` name; Fiasp/Lyumjev peak at 55 min.
        init(model: String?) {
            switch model?.lowercased() {
            case let name? where name.contains("fiasp") || name.contains("lyumjev"): peak = 55 * 60
            case let name? where name.contains("child"): peak = 65 * 60
            case let name? where name.contains("adult"): peak = 75 * 60
            default: break
            }
        }

        init(peak: TimeInterval, duration: TimeInterval, delay: TimeInterval) {
            self.peak = peak
            self.duration = duration
            self.delay = delay
        }

        /// Share of a dose still to act `elapsed` seconds after it was given.
        func remaining(after elapsed: TimeInterval) -> Double {
            let t = (elapsed - delay) / 60
            let td = duration / 60
            let tp = peak / 60
            if t <= 0 { return 1 }
            if t >= td { return 0 }
            let tau = tp * (1 - tp / td) / (1 - 2 * tp / td)
            let a = 2 * tau / td
            let s = 1 / (1 - a + (1 + a) * exp(-td / tau))
            return 1 - s * (1 - a) * ((t * t / (tau * td * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
        }
    }

    struct Assessment: Equatable {
        let date: Date
        let glucose: Double
        /// Observed change over the window.
        let observedChange: Double
        /// How far the insulin acting in the window should have lowered glucose.
        let insulinDrop: Double
        /// How far the carbs absorbed in the window should have raised it.
        let carbRise: Double
        /// Glucose change over the last 30 minutes.
        let recentChange: Double

        /// What the insulin and carbs do not explain; positive means higher than expected.
        var unexplainedRise: Double { observedChange - carbRise + insulinDrop }
    }

    struct Limits: Equatable {
        /// Glucose at or above this.
        var glucose: Double = 288
        /// Rise the insulin and carbs do not explain, at or above this.
        var unexplainedRise: Double = 144
        /// Drop the insulin should have caused, at or above this — keeps quiet when
        /// too little insulin was given for its absence to show.
        var insulinDrop: Double = 180
        /// Every reading over this long must meet the limits.
        var persistent: TimeInterval = 30 * 60
        /// Counts as falling, which never alarms.
        var falling: Double = -9
    }

    static let window: TimeInterval = 90 * 60

    var glucose: [GlucoseValue]
    var doses: [Dose]
    var carbs: [Carb]
    /// mg/dL per unit.
    var sensitivity: Schedule
    /// Grams per unit.
    var carbRatio: Schedule
    var curve: InsulinCurve

    // MARK: - Effects

    func insulinDrop(from start: Date, to end: Date) -> Double {
        doses.reduce(0) { sum, dose in
            guard dose.start < end, let isf = sensitivity.value(at: dose.start) else { return sum }
            // Basal runs over time; spread it in 5-minute pieces.
            let pieces = max(1, Int(ceil(dose.end.timeIntervalSince(dose.start) / 300)))
            let step = dose.end.timeIntervalSince(dose.start) / Double(pieces)
            var effect = 0.0
            for i in 0 ..< pieces {
                let at = dose.start.addingTimeInterval((Double(i) + 0.5) * step)
                guard at < end else { break }
                let acted = curve.remaining(after: start.timeIntervalSince(at)) - curve.remaining(after: end.timeIntervalSince(at))
                effect += dose.units / Double(pieces) * acted
            }
            return sum + effect * isf
        }
    }

    func carbRise(from start: Date, to end: Date) -> Double {
        carbs.reduce(0) { sum, carb in
            guard carb.date < end, carb.absorption > 0,
                  let isf = sensitivity.value(at: carb.date),
                  let ratio = carbRatio.value(at: carb.date), ratio > 0
            else { return sum }
            func absorbed(by date: Date) -> Double {
                let t = date.timeIntervalSince(carb.date) - 10 * 60
                return min(1, max(0, t / carb.absorption))
            }
            return sum + carb.grams * (absorbed(by: end) - absorbed(by: start)) * isf / ratio
        }
    }

    // MARK: - Assessment

    /// The nearest reading within 5 minutes of `date`.
    func glucose(near date: Date) -> GlucoseValue? {
        glucose
            .filter { abs($0.date.timeIntervalSince(date)) <= 5 * 60 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    func assess(at reading: GlucoseValue) -> Assessment? {
        guard let before = glucose(near: reading.date.addingTimeInterval(-Self.window)),
              let recent = glucose(near: reading.date.addingTimeInterval(-30 * 60))
        else { return nil }
        let start = before.date
        return Assessment(
            date: reading.date,
            glucose: Double(reading.sgv),
            observedChange: Double(reading.sgv - before.sgv),
            insulinDrop: insulinDrop(from: start, to: reading.date),
            carbRise: carbRise(from: start, to: reading.date),
            recentChange: Double(reading.sgv - recent.sgv)
        )
    }

    func meets(_ assessment: Assessment, _ limits: Limits) -> Bool {
        assessment.glucose >= limits.glucose
            && assessment.unexplainedRise >= limits.unexplainedRise
            && assessment.insulinDrop >= limits.insulinDrop
            && assessment.recentChange > limits.falling
    }

    /// The latest assessment when every reading over `limits.persistent` meets the
    /// limits, nil otherwise. A gap in the readings breaks the run.
    func suspectedFailure(now: Date, limits: Limits) -> Assessment? {
        guard let latest = glucose.last, now.timeIntervalSince(latest.date) <= 10 * 60 else { return nil }
        let since = latest.date.addingTimeInterval(-limits.persistent)
        let run = glucose.filter { $0.date >= since.addingTimeInterval(-60) }
        guard let first = run.first, first.date <= since.addingTimeInterval(4 * 60) else { return nil }
        for (earlier, later) in zip(run, run.dropFirst()) where later.date.timeIntervalSince(earlier.date) > 11 * 60 {
            return nil
        }
        var last: Assessment?
        for reading in run {
            guard let assessment = assess(at: reading), meets(assessment, limits) else { return nil }
            last = assessment
        }
        return last
    }
}
