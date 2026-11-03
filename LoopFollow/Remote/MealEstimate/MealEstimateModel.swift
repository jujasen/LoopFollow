// LoopFollow
// MealEstimateModel.swift

import Foundation
import UIKit

/// The state behind the "describe the meal" card: what is typed, the photos waiting to go, the
/// conversation so far and the latest estimate. The carb screen watches `estimate` and fills in
/// its fields from each new one; nothing is ever sent from here.
@MainActor
final class MealEstimateModel: ObservableObject {
    @Published var description = ""
    @Published var followUp = ""
    @Published private(set) var photos: [Data] = []
    @Published private(set) var estimate: MealCarbEstimate?
    @Published private(set) var isEstimating = false
    @Published var error: String?

    private(set) var conversation: [MealCarbEstimator.Message] = []
    private var task: Task<Void, Never>?
    private let estimator: MealCarbEstimator?

    init(estimator: MealCarbEstimator? = MealCarbEstimator.shared) {
        self.estimator = estimator
    }

    /// False without a built-in key; the card is then not shown.
    var isAvailable: Bool { estimator != nil }

    var canEstimate: Bool {
        !isEstimating && (!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
    }

    var canRefine: Bool {
        !isEstimating && estimate != nil && (!followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
    }

    var canAddPhoto: Bool {
        !isEstimating && photos.count < MealCarbEstimator.maxPhotosPerMessage
    }

    /// Photos behind the current estimate, counting every message of the conversation.
    var estimatePhotoCount: Int {
        conversation.reduce(0) { $0 + $1.images.count }
    }

    func addPhoto(_ image: UIImage) {
        guard canAddPhoto, let photo = MealCarbEstimator.preparedPhoto(image) else { return }
        photos.append(photo)
    }

    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }

    /// Starts a fresh estimate from the description and any photos.
    func estimateMeal() {
        guard canEstimate else { return }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        request(Self.firstMessage(text: text, photos: photos))
    }

    /// Adds what was forgotten — in words, photos or both — and asks for a new estimate of the
    /// whole meal, sending the conversation so far along with it.
    func refine() {
        guard canRefine, let estimate else { return }
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        request(Self.followUpConversation(conversation, estimate: estimate, text: text, photos: photos))
    }

    /// Stops an estimate on its way, leaving the text and photos to be corrected and sent again.
    func cancel() {
        task?.cancel()
        task = nil
        isEstimating = false
    }

    /// Forgets the estimate. The fields it filled in stay as they are.
    func clear() {
        cancel()
        estimate = nil
        error = nil
        conversation = []
        description = ""
        followUp = ""
        photos = []
    }

    nonisolated static func firstMessage(text: String, photos: [Data]) -> [MealCarbEstimator.Message] {
        [MealCarbEstimator.Message(role: "user", content: text.isEmpty ? "Estimate the meal in the photos." : text, images: photos)]
    }

    nonisolated static func followUpConversation(_ conversation: [MealCarbEstimator.Message], estimate: MealCarbEstimate, text: String, photos: [Data]) -> [MealCarbEstimator.Message] {
        conversation + [
            MealCarbEstimator.assistantMessage(for: estimate),
            MealCarbEstimator.Message(
                role: "user",
                content: text.isEmpty ? "More photos of the same meal." : "More information about the same meal: \(text)",
                images: photos
            ),
        ]
    }

    private func request(_ conversation: [MealCarbEstimator.Message]) {
        guard let estimator else { return }
        task?.cancel()
        isEstimating = true
        error = nil
        task = Task { [weak self] in
            do {
                let estimate = try await estimator.estimate(conversation: conversation)
                guard let self, !Task.isCancelled else { return }
                self.conversation = conversation
                self.estimate = estimate
                self.followUp = ""
                self.photos = []
                self.isEstimating = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isEstimating = false
                self.error = error.localizedDescription
            }
        }
    }
}
