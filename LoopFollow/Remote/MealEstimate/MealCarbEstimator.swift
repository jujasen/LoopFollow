// LoopFollow
// MealCarbEstimator.swift

// Turns a free-text meal description ("en brødskive med leverpostei og et glass melk"), photos of
// the plate, or both, into what the carb screen needs — grams, absorption time, an emoji and a
// name — by asking Claude. A follow-up ("he only ate half") sends the whole conversation again,
// and the meal is re-evaluated with everything said so far.
//
// This is the same estimate as Loop's carb screen (Loop's `MealCarbEstimator.swift`): the same
// system prompt and JSON schema, so both apps answer alike. Change both together.
//
// The estimate only fills in the fields. Nothing is sent to Loop until the caregiver has
// reviewed the numbers and confirmed the carbs as usual.

import Foundation
import UIKit

/// One estimate for the whole meal, as returned by the model.
struct MealCarbEstimate: Codable, Equatable {
    struct Item: Codable, Equatable, Hashable {
        var food: String
        var amount: String
        var carbsGrams: Double

        enum CodingKeys: String, CodingKey {
            case food, amount
            case carbsGrams = "carbs_grams"
        }
    }

    enum Confidence: String, Codable {
        case high, medium, low
    }

    var name: String
    var emoji: String
    var carbsGrams: Double
    var absorptionHours: Double
    var items: [Item]
    var assumptions: [String]
    var confidence: Confidence
    var fatGrams: Double? = nil
    var proteinGrams: Double? = nil

    enum CodingKeys: String, CodingKey {
        case name, emoji, items, assumptions, confidence
        case carbsGrams = "carbs_grams"
        case absorptionHours = "absorption_hours"
        case fatGrams = "fat_grams"
        case proteinGrams = "protein_grams"
    }

    /// Grams rounded to one decimal, never negative.
    var roundedCarbs: Double {
        guard carbsGrams.isFinite else { return 0 }
        return max(0, (carbsGrams * 10).rounded() / 10)
    }

    /// Absorption time in seconds, in half hours between 30 minutes and 8 hours — what the
    /// carb screen's pickers can show — whatever the model returned.
    var absorptionTime: TimeInterval {
        let hours = absorptionHours.isFinite ? absorptionHours : 3
        return FavoriteFoodAbsorption.clamped(hours * 3600)
    }

    /// A single emoji for the food type; the model occasionally returns more than one.
    var foodTypeEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "🍽️" }
        return String(first)
    }

    /// "🍕 Pizza", as Loop stores the dish in `foodType`.
    var foodType: String? {
        CarbFoodLabel(emoji: foodTypeEmoji, name: name).foodType
    }
}

final class MealCarbEstimator {
    enum EstimateError: LocalizedError, Equatable {
        case network(String)
        case server(String)
        case refused(String)
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case let .network(message), let .server(message), let .refused(message):
                return message
            case .unreadableResponse:
                return String(localized: "The estimate could not be read. Try again.", table: "MealEstimate", comment: "Error shown when the meal estimate response could not be parsed")
            }
        }
    }

    struct Message: Equatable {
        var role: String
        var content: String
        /// JPEG photos sent with `content` (see `preparedPhoto(_:)`). Kept with the message so a
        /// follow-up still shows the model the same plate.
        var images: [Data] = []
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicVersion = "2026-10-21"
    /// Tried in order; the next one is used only when a model is unknown to the key.
    static let models = ["claude-sonnet-5-5", "claude-haiku-5-5"]
    /// How many photos one message may carry.
    static let maxPhotosPerMessage = 4

    /// Built in at build time (`ANTHROPIC_API_KEY` in the xcconfig, `AnthropicAPIKey` in
    /// Info.plist). Without it the meal estimate stays hidden.
    static let shared: MealCarbEstimator? = builtInKey(Bundle.main.infoDictionary).map { MealCarbEstimator(apiKey: $0) }

    static func builtInKey(_ info: [String: Any]?) -> String? {
        guard let key = info?["AnthropicAPIKey"] as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Asks for a complete estimate of the meal described across `conversation`, which alternates
    /// the caregiver's descriptions with the model's earlier estimates.
    func estimate(conversation: [Message]) async throws -> MealCarbEstimate {
        // Photos make the model take noticeably longer.
        let timeout: TimeInterval = conversation.contains { !$0.images.isEmpty } ? 120 : 60
        var lastError = EstimateError.server("No AI model available")
        for model in Self.models {
            let request = try Self.request(model: model, conversation: conversation, apiKey: apiKey, timeout: timeout)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw EstimateError.network(error.localizedDescription)
            }
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                let message = Self.serverMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                if Self.isUnknownModel(message, statusCode: http.statusCode) {
                    lastError = .server(message)
                    continue
                }
                throw EstimateError.server(message)
            }
            return try Self.parseResponse(data)
        }
        throw lastError
    }

    // MARK: - Request

    static func request(model: String, conversation: [Message], apiKey: String, timeout: TimeInterval = 60) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(model: model, conversation: conversation))
        return request
    }

    /// A Claude Messages request: the system prompt cached, low effort (someone is waiting), and
    /// the answer held to the meal estimate schema. Thinking is left to the model (adaptive).
    static func requestBody(model: String, conversation: [Message]) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "system": [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": conversation.map { ["role": $0.role == "assistant" ? "assistant" : "user", "content": content(of: $0)] },
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// Plain text, or — with photos — the text followed by the photos as base64 image blocks.
    static func content(of message: Message) -> Any {
        guard !message.images.isEmpty else { return message.content }
        var blocks: [[String: Any]] = []
        if !message.content.isEmpty {
            blocks.append(["type": "text", "text": message.content])
        }
        for image in message.images {
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()],
            ])
        }
        return blocks
    }

    /// Scales a photo down to what the model needs to read a plate and re-encodes it as JPEG, so a
    /// few photos upload quickly on a phone connection.
    static func preparedPhoto(_ image: UIImage, maxDimension: CGFloat = 1024) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    // MARK: - Response

    static func parseResponse(_ data: Data) throws -> MealCarbEstimate {
        struct Response: Decodable {
            struct Block: Decodable {
                var type: String
                var text: String?
            }

            struct StopDetails: Decodable {
                var explanation: String?
            }

            var content: [Block]
            var stop_reason: String?
            var stop_details: StopDetails?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw EstimateError.unreadableResponse
        }
        if response.stop_reason == "refusal" {
            throw EstimateError.refused(response.stop_details?.explanation ?? "Claude declined to answer.")
        }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let json = text.data(using: .utf8),
              let estimate = try? JSONDecoder().decode(MealCarbEstimate.self, from: json),
              estimate.carbsGrams.isFinite
        else {
            throw EstimateError.unreadableResponse
        }
        return estimate
    }

    /// The `error.message` the API answers with on failure.
    static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { var message: String }
            var error: Detail
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
    }

    /// True when the API says the model does not exist or the key cannot use it.
    static func isUnknownModel(_ message: String, statusCode: Int) -> Bool {
        let lowered = message.lowercased()
        guard lowered.contains("model") else { return false }
        return statusCode == 404 || lowered.contains("not found") || lowered.contains("does not exist")
            || lowered.contains("do not have access") || lowered.contains("not supported") || lowered.contains("invalid model")
    }

    /// The model's estimate as it goes back into the conversation, so a follow-up is judged
    /// against what it said before.
    static func assistantMessage(for estimate: MealCarbEstimate) -> Message {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = (try? encoder.encode(estimate)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Message(role: "assistant", content: content)
    }

    // MARK: - Prompt and schema (same as Loop's)

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "emoji", "carbs_grams", "absorption_hours", "items", "assumptions", "confidence", "fat_grams", "protein_grams"],
        "properties": [
            "name": ["type": "string"],
            "emoji": ["type": "string"],
            "carbs_grams": ["type": "number"],
            "absorption_hours": ["type": "number"],
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["food", "amount", "carbs_grams"],
                    "properties": [
                        "food": ["type": "string"],
                        "amount": ["type": "string"],
                        "carbs_grams": ["type": "number"],
                    ],
                ] as [String: Any],
            ] as [String: Any],
            "assumptions": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]] as [String: Any],
            "fat_grams": ["type": "number"],
            "protein_grams": ["type": "number"],
        ] as [String: Any],
    ]

    static let systemPrompt = """
    You estimate carbohydrates for meals logged in Loop, an automated insulin delivery app for a young child with type 1 diabetes. The caregiver describes a meal in free text, usually in Norwegian. Your estimate fills in the carb entry, and the caregiver reviews it before any insulin is given.

    Return:
    - name: a short name for the meal (2-4 words), in the caregiver's language.
    - emoji: exactly one emoji for the main food of the meal (for example 🥪 for open sandwiches, not the drink next to them).
    - carbs_grams: total digestible carbohydrates in grams for the amount actually eaten. Count available carbohydrate as on Norwegian and European labels (fibre is not included).
    - absorption_hours: how long the carbs take to absorb, between 0.5 and 8, in steps of 0.5. Loop's reference points: 2 h for fast carbs (juice, fruit, candy, white bread alone), 3 h for an ordinary mixed meal, 4 h for slow meals (pasta, rice, whole grains, or meals with moderate fat and protein), 5-6 h for very fatty or protein-heavy meals (pizza, taco, burgers, creamy sauces).
    - items: each component with the amount you assumed and its carbs. The item carbs must add up to carbs_grams.
    - assumptions: short notes, in the caregiver's language, on anything you had to guess — portion size, brand, recipe. Empty when nothing was guessed.
    - confidence: high when amounts and foods are clear, medium when portions had to be guessed, low when the description is vague.
    - fat_grams and protein_grams: total fat and protein in grams for the amount actually eaten, from Norwegian food tables (Matvaretabellen) and labels. Count butter, oil, cheese, cream and whole milk that go with the food.

    The caregiver may attach one or more photos of the meal, with or without text. Use them to identify the foods and judge the portions — the plate, cutlery, a glass or a hand gives the scale. Several photos are of the same meal, from different angles or at different moments; do not count food twice. When a photo shows a nutrition label, use its carbohydrate values. When the text and the photos disagree, the text wins, since the caregiver knows what was actually eaten. Name in assumptions anything in the photos you could not identify.

    When no amount is given, assume a typical portion for a small child and say so in assumptions. Use Norwegian products and recipes when the food is Norwegian. When the caregiver adds more information later, re-evaluate the whole meal from scratch with everything you know, and return a complete new estimate, not just the change. Never give insulin or dosing advice.
    """
}
