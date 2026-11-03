// LoopFollow
// MealCarbEstimatorTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The AI meal estimate on the carb screen: the Claude request it builds and the answers it
/// reads. No network.
struct MealCarbEstimatorTests {
    private static let estimateJSON = """
    {"name":"Fiskegrateng","emoji":"🐟","carbs_grams":32.46,"absorption_hours":3.5,"items":[{"food":"Fiskegrateng","amount":"200 g","carbs_grams":24},{"food":"Gulrøtter","amount":"50 g","carbs_grams":8.46}],"assumptions":["Vanlig porsjon for et lite barn"],"confidence":"medium","fat_grams":12,"protein_grams":18}
    """

    private static func claudeResponse(text: String, stopReason: String = "end_turn") -> Data {
        let body: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-5-5",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "x"],
                ["type": "text", "text": text],
            ],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Request

    @Test("posts to the Messages API with the key and version headers")
    func requestHeaders() throws {
        let request = try MealCarbEstimator.request(model: "claude-sonnet-5-5", conversation: [.init(role: "user", content: "Pizza")], apiKey: "test-key")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("asks for the meal schema with a cached system prompt")
    func requestBody() throws {
        let body = try Self.json(MealCarbEstimator.request(model: "claude-sonnet-5-5", conversation: [.init(role: "user", content: "Pizza")], apiKey: "k"))
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 16000)
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] == nil)

        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == MealCarbEstimator.systemPrompt)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["name", "emoji", "carbs_grams", "absorption_hours", "items", "assumptions", "confidence", "fat_grams", "protein_grams"])

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Pizza")
    }

    @Test("photos go as base64 JPEG image blocks after the text")
    func photos() throws {
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let conversation = MealEstimateModel.firstMessage(text: "Middag", photos: [photo, photo])
        let body = try Self.json(MealCarbEstimator.request(model: "claude-sonnet-5-5", conversation: conversation, apiKey: "k"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "Middag")
        for block in blocks.dropFirst() {
            #expect(block["type"] as? String == "image")
            let source = try #require(block["source"] as? [String: Any])
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == "image/jpeg")
            #expect(source["data"] as? String == photo.base64EncodedString())
        }
    }

    @Test("photos alone ask for the meal in the photos")
    func photosWithoutText() {
        let conversation = MealEstimateModel.firstMessage(text: "", photos: [Data([1])])
        #expect(conversation[0].content == "Estimate the meal in the photos.")
        #expect(conversation[0].images.count == 1)
    }

    @Test("a follow-up sends the whole conversation with the earlier estimate")
    func followUp() throws {
        let estimate = try MealCarbEstimator.parseResponse(Self.claudeResponse(text: Self.estimateJSON))
        let first = MealEstimateModel.firstMessage(text: "Fiskegrateng", photos: [])
        let conversation = MealEstimateModel.followUpConversation(first, estimate: estimate, text: "spiste bare halve", photos: [])
        let body = try Self.json(MealCarbEstimator.request(model: "claude-sonnet-5-5", conversation: conversation, apiKey: "k"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages[2]["content"] as? String == "More information about the same meal: spiste bare halve")

        // The earlier estimate goes back as the JSON it was.
        let previous = try #require((messages[1]["content"] as? String)?.data(using: .utf8))
        #expect(try JSONDecoder().decode(MealCarbEstimate.self, from: previous) == estimate)
    }

    @Test("Sonnet first, Haiku as reserve")
    func models() {
        #expect(MealCarbEstimator.models == ["claude-sonnet-5-5", "claude-haiku-5-5"])
    }

    // MARK: - Response

    @Test("reads the estimate from the text block, skipping thinking")
    func parses() throws {
        let estimate = try MealCarbEstimator.parseResponse(Self.claudeResponse(text: Self.estimateJSON))
        #expect(estimate.name == "Fiskegrateng")
        #expect(estimate.foodTypeEmoji == "🐟")
        #expect(estimate.foodType == "🐟 Fiskegrateng")
        #expect(estimate.roundedCarbs == 32.5)
        #expect(estimate.absorptionTime == 3.5 * 3600)
        #expect(estimate.items.count == 2)
        #expect(estimate.confidence == .medium)
        #expect(estimate.fatGrams == 12)
        #expect(estimate.proteinGrams == 18)
    }

    @Test("absorption is held to half hours between 30 minutes and 8 hours")
    func absorption() throws {
        var estimate = try MealCarbEstimator.parseResponse(Self.claudeResponse(text: Self.estimateJSON))
        estimate.absorptionHours = 12
        #expect(estimate.absorptionTime == 8 * 3600)
        estimate.absorptionHours = 0.1
        #expect(estimate.absorptionTime == 30 * 60)
        estimate.absorptionHours = 2.7
        #expect(estimate.absorptionTime == 2.5 * 3600)
        estimate.absorptionHours = .nan
        #expect(estimate.absorptionTime == 3 * 3600)
    }

    @Test("keeps a single emoji and never negative carbs")
    func emojiAndCarbs() throws {
        var estimate = try MealCarbEstimator.parseResponse(Self.claudeResponse(text: Self.estimateJSON))
        estimate.emoji = "🍕🥤"
        #expect(estimate.foodTypeEmoji == "🍕")
        estimate.emoji = " "
        #expect(estimate.foodTypeEmoji == "🍽️")
        estimate.carbsGrams = -4
        #expect(estimate.roundedCarbs == 0)
    }

    @Test("a refusal is an error with Claude's explanation")
    func refusal() throws {
        var body = try #require(JSONSerialization.jsonObject(with: Self.claudeResponse(text: "", stopReason: "refusal")) as? [String: Any])
        body["stop_details"] = ["type": "refusal", "category": NSNull(), "explanation": "Kan ikke svare"]
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(throws: MealCarbEstimator.EstimateError.refused("Kan ikke svare")) {
            try MealCarbEstimator.parseResponse(data)
        }
    }

    @Test("unreadable answers are errors")
    func unreadable() {
        #expect(throws: MealCarbEstimator.EstimateError.unreadableResponse) {
            try MealCarbEstimator.parseResponse(Self.claudeResponse(text: "{\"name\":\"Pizza\"}"))
        }
        #expect(throws: MealCarbEstimator.EstimateError.unreadableResponse) {
            try MealCarbEstimator.parseResponse(Data("not json".utf8))
        }
    }

    @Test("reads the API's error message and spots an unknown model")
    func errors() {
        let data = Data(#"{"type":"error","error":{"type":"not_found_error","message":"model: claude-sonnet-5-5"}}"#.utf8)
        let message = MealCarbEstimator.serverMessage(from: data)
        #expect(message == "model: claude-sonnet-5-5")
        #expect(MealCarbEstimator.isUnknownModel(message ?? "", statusCode: 404))
        #expect(!MealCarbEstimator.isUnknownModel("invalid x-api-key", statusCode: 401))
        #expect(!MealCarbEstimator.isUnknownModel("Overloaded", statusCode: 529))
    }

    // MARK: - Key

    @Test("the card is hidden without a built-in key")
    func builtInKey() {
        #expect(MealCarbEstimator.builtInKey(nil) == nil)
        #expect(MealCarbEstimator.builtInKey(["AnthropicAPIKey": ""]) == nil)
        #expect(MealCarbEstimator.builtInKey(["AnthropicAPIKey": "$(ANTHROPIC_API_KEY)"]) == nil)
        #expect(MealCarbEstimator.builtInKey(["AnthropicAPIKey": " sk-test \n"]) == "sk-test")
    }

    @Test("same system prompt as Loop")
    func samePromptAsLoop() {
        #expect(MealCarbEstimator.systemPrompt.hasPrefix("You estimate carbohydrates for meals logged in Loop"))
        #expect(MealCarbEstimator.systemPrompt.hasSuffix("Never give insulin or dosing advice."))
    }
}
