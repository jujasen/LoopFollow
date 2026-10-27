// LoopFollow
// LoopInsight.swift

// The glucose insight Loop keeps through the day — today, the weeks behind, the parts of the
// day, and how the AI doses went — read from Nightscout, where Loop puts it as one document in
// the food collection (type "loopInsight", always the same _id). The models mirror Loop's
// GlucoseInsight; every number is worked out in Loop.

import Foundation

struct LoopInsightPeriod: Codable, Equatable {
    var meanMmol: Double
    var timeInRangePercent: Int
    var belowRangePercent: Int
    var aboveRangePercent: Int
    var lowEpisodes: Int
    var readings: Int
}

struct LoopInsightMeal: Codable, Equatable {
    enum Flag: String, Codable {
        case extraCarbs = "extra_carbs"
        case correction
        case treatedLow = "treated_low"
        case startedLow = "started_low"
        case unfinished
    }

    var date: Date
    var daypart: String
    var carbsGrams: Double
    var foods: [String]
    var bolusUnits: Double
    var automaticUnitsWithin3h: Double
    var startMmol: Double?
    var peakMmol: Double?
    var after2hMmol: Double?
    var after3hMmol: Double?
    var lowestWithin4hMmol: Double?
    var flags: [Flag]

    /// A flag this app doesn't know yet is left out rather than losing the meal.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        daypart = try container.decode(String.self, forKey: .daypart)
        carbsGrams = try container.decode(Double.self, forKey: .carbsGrams)
        foods = try container.decodeIfPresent([String].self, forKey: .foods) ?? []
        bolusUnits = try container.decode(Double.self, forKey: .bolusUnits)
        automaticUnitsWithin3h = try container.decodeIfPresent(Double.self, forKey: .automaticUnitsWithin3h) ?? 0
        startMmol = try container.decodeIfPresent(Double.self, forKey: .startMmol)
        peakMmol = try container.decodeIfPresent(Double.self, forKey: .peakMmol)
        after2hMmol = try container.decodeIfPresent(Double.self, forKey: .after2hMmol)
        after3hMmol = try container.decodeIfPresent(Double.self, forKey: .after3hMmol)
        lowestWithin4hMmol = try container.decodeIfPresent(Double.self, forKey: .lowestWithin4hMmol)
        flags = (try container.decodeIfPresent([String].self, forKey: .flags) ?? []).compactMap(Flag.init(rawValue:))
    }
}

struct LoopInsightDaypart: Codable, Equatable {
    var name: String
    var last7Days: LoopInsightPeriod?
    var last30Days: LoopInsightPeriod?
    var loopForecastError1hMmol: Double?
    var loopForecastError2hMmol: Double?
    var forecastChecks: Int
    var cleanMeals: Int
    var medianGramsPerUnit: Double?
    var medianRiseMmol: Double?
    var median3hChangeMmol: Double?
    var lowAfterMealPercent: Int?
    var highAt3hPercent: Int?
}

struct LoopInsightAdvice: Codable, Equatable {
    var date: Date
    var loopUnits: Double?
    var suggestedUnits: Double
    var accepted: Bool
    var after3hMmol: Double?
    var lowestWithin4hMmol: Double?
}

struct LoopInsightLongTerm: Codable, Equatable {
    var days: Int
    var last7Days: LoopInsightPeriod?
    var earlierDays: LoopInsightPeriod?
    var dayparts: [LoopInsightDaypart]
    var weekdayDaytime: LoopInsightPeriod?
    var weekendDaytime: LoopInsightPeriod?
    var averageDailyCarbsGrams: Double
    var averageDailyBolusUnits: Double
    var advice: [LoopInsightAdvice]
    /// What the settings suggestions are built on; read but not shown. Absent in older documents.
    var patterns: [LoopInsightPattern]?
    var computedAt: Date
}

/// How often a part of the day went high or low after meals and at night, over the last two weeks.
struct LoopInsightPattern: Codable, Equatable {
    var daypart: String
    var daysWithData: Int
    var highAfterMealDays: Int
    var lowAfterMealDays: Int
    var lowDays: Int
    var highDays: Int
    var risingNights: Int?
    var fallingNights: Int?
}

/// A change to the therapy settings the AI suggests, kept by Loop only when the pattern behind it
/// was seen on at least three days.
struct LoopInsightSuggestion: Codable, Hashable {
    enum Setting: String, Codable {
        case carbRatio = "carb_ratio"
        case insulinSensitivity = "insulin_sensitivity"
        case basalRate = "basal_rate"
    }

    var setting: Setting
    var daypart: String
    var startHour: Int
    var endHour: Int
    var current: Double
    var proposed: Double
    var reason: String
    var evidenceDays: Int

    /// More insulin than now: a lower carb ratio or sensitivity, or a higher basal rate.
    var givesMoreInsulin: Bool {
        setting == .basalRate ? proposed > current : proposed < current
    }
}

struct LoopInsightToday: Codable, Equatable {
    var period: LoopInsightPeriod?
    var lowEpisodeStarts: [Date]
    var hoursAboveTen: Double
    var meals: [LoopInsightMeal]
    var loopForecastError1hMmol: Double?
    var usualForecastError1hMmol: Double?
    var forecastDeviationMmol: Double?
    var computedAt: Date
}

struct LoopInsightText: Codable, Equatable {
    var summary: String
    var points: [String]
    var doseHints: [String]
    var createdAt: Date
    /// Today only: the situation right now, in one sentence.
    var now: String?
    /// Today only: what to do now, when something should be done.
    var action: String?
    /// The weeks behind only: settings changes the AI suggests.
    var suggestions: [LoopInsightSuggestion]?

    enum CodingKeys: String, CodingKey {
        case summary, points, now, action, suggestions
        case doseHints = "dose_hints"
        case createdAt = "created_at"
    }

    init(summary: String, points: [String] = [], doseHints: [String] = [], createdAt: Date, now: String? = nil, action: String? = nil, suggestions: [LoopInsightSuggestion]? = nil) {
        self.summary = summary
        self.points = points
        self.doseHints = doseHints
        self.createdAt = createdAt
        self.now = now
        self.action = action
        self.suggestions = suggestions
    }

    /// Everything but the summary and time may be missing; a suggestion this app can't read is
    /// left out rather than losing the text.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        points = try container.decodeIfPresent([String].self, forKey: .points) ?? []
        doseHints = try container.decodeIfPresent([String].self, forKey: .doseHints) ?? []
        now = try container.decodeIfPresent(String.self, forKey: .now).flatMap { $0.isEmpty ? nil : $0 }
        action = try container.decodeIfPresent(String.self, forKey: .action).flatMap { $0.isEmpty ? nil : $0 }
        suggestions = try container.decodeIfPresent([LoopInsightLossy<LoopInsightSuggestion>].self, forKey: .suggestions)?.compactMap(\.value)
    }
}

/// Decodes to nil instead of failing the array around it.
struct LoopInsightLossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct LoopInsightStatus: Codable, Equatable {
    var longTerm: LoopInsightLongTerm?
    var today: LoopInsightToday?
    var longTermText: LoopInsightText?
    var todayText: LoopInsightText?
    var dataUpdatedAt: Date?
    var lastError: String?
}

/// The document as Loop uploads it.
struct LoopInsightDocument: Codable, Equatable {
    static let id = "6c6f6f70696e736967687431"
    static let documentType = "loopInsight"

    struct Usage: Codable, Equatable {
        var calls: Int
        var dollars: Double
    }

    var type: String
    var version: Int
    var uploadedAt: Date
    var aiEnabled: Bool
    var aiUsageToday: Usage
    var insight: LoopInsightStatus

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Loop's document among everything in the food collection, or nil when there is none.
    static func find(in foods: [[String: Any]]) -> LoopInsightDocument? {
        let candidates = foods.filter { ($0["_id"] as? String) == id || ($0["type"] as? String) == documentType }
        return candidates
            .compactMap { raw -> LoopInsightDocument? in
                var raw = raw
                raw.removeValue(forKey: "_id")
                guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                return try? decoder().decode(LoopInsightDocument.self, from: data)
            }
            .max { $0.uploadedAt < $1.uploadedAt }
    }
}

/// Reads the insight from Nightscout and keeps the last one, so the tab has something offline.
@MainActor
final class LoopInsightStore: ObservableObject {
    static let shared = LoopInsightStore()

    @Published private(set) var document: LoopInsightDocument?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let cacheKey = "loopInsightDocument"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey) {
            document = try? LoopInsightDocument.decoder().decode(LoopInsightDocument.self, from: data)
        }
    }

    /// Reads again unless it was read in the last minute, or `force`.
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 { return }
        let url = Storage.shared.url.value
        guard !url.isEmpty,
              let requestURL = NightscoutUtils.constructURL(baseURL: url, token: Storage.shared.token.value, endpoint: "/api/v1/food/", parameters: [:])
        else {
            errorMessage = String(localized: "Nightscout is not set up.", table: "LoopInsight", comment: "Insight tab error: no Nightscout address")
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let foods = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            fetchedAt = Date()
            if let found = LoopInsightDocument.find(in: foods) {
                document = found
                errorMessage = nil
                if let encoded = try? Self.encoder().encode(found) {
                    UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
                }
            } else {
                errorMessage = String(localized: "Loop hasn't put an insight in Nightscout yet.", table: "LoopInsight", comment: "Insight tab: no document in Nightscout")
            }
        } catch {
            errorMessage = String(localized: "Couldn't read Nightscout.", table: "LoopInsight", comment: "Insight tab error: the request failed") + " " + error.localizedDescription
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
