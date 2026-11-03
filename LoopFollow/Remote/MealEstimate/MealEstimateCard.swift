// LoopFollow
// MealEstimateCard.swift

// The "describe the meal" card on the carb screen, under the ordinary fields, as on Loop's carb
// screen (Loop's `MealEstimateCard.swift`): free text and/or photos of the meal in, carbs,
// absorption time and the dish filled into the fields above. The breakdown and the guesses
// behind the numbers open under "Show calculation", and a follow-up re-evaluates the whole meal.

import PhotosUI
import SwiftUI

struct MealEstimateSection: View {
    @ObservedObject var model: MealEstimateModel

    var body: some View {
        if model.isAvailable {
            Section {
                MealEstimateCard(model: model)
            } header: {
                Text("Describe the meal", tableName: "MealEstimate", comment: "Section title for the meal estimate card on the carb screen")
            } footer: {
                if model.estimate != nil {
                    Text("AI estimate — check the numbers before you continue.", tableName: "MealEstimate", comment: "Reminder under the meal estimate that the numbers must be reviewed")
                }
            }
        }
    }
}

struct MealEstimateCard: View {
    @ObservedObject var model: MealEstimateModel

    @FocusState private var isInputFocused: Bool
    @State private var showsBreakdown = false
    @State private var photoSource: PhotoSource?

    private enum PhotoSource: Int, Identifiable {
        case camera, library
        var id: Int { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let estimate = model.estimate {
                summary(for: estimate)

                if showsBreakdown {
                    breakdown(for: estimate)
                        .transition(.opacity)
                }

                photoStrip

                promptField(
                    String(localized: "Add or correct something…", table: "MealEstimate", comment: "Placeholder for adding more information to a meal estimate"),
                    text: $model.followUp,
                    isEnabled: model.canRefine,
                    accessibilityLabel: String(localized: "Update estimate", table: "MealEstimate", comment: "Button label asking AI to re-evaluate the meal with the added information"),
                    action: model.refine
                )
            } else {
                photoStrip

                promptField(
                    String(localized: "E.g. fish gratin", table: "MealEstimate", comment: "Placeholder for the free-text meal description on the carb screen"),
                    text: $model.description,
                    isEnabled: model.canEstimate,
                    accessibilityLabel: String(localized: "Estimate carbs", table: "MealEstimate", comment: "Button label asking AI to estimate the carbs of the described meal"),
                    action: model.estimateMeal
                )
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: showsBreakdown)
        .animation(.easeInOut(duration: 0.2), value: model.estimate)
        .animation(.easeInOut(duration: 0.2), value: model.photos)
        .fullScreenCover(item: $photoSource) { source in
            switch source {
            case .camera:
                CameraPicker { image in model.addPhoto(image) }
                    .ignoresSafeArea()
            case .library:
                PhotoLibraryPicker(limit: MealCarbEstimator.maxPhotosPerMessage - model.photos.count) { images in
                    images.forEach(model.addPhoto)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Input

    /// The photos that go with the next message, each with a button to take it out again.
    @ViewBuilder
    private var photoStrip: some View {
        if !model.photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.photos.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button(action: { model.removePhoto(at: index) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.isEstimating)
                                    .padding(3)
                                    .accessibilityLabel(Text("Remove photo", tableName: "MealEstimate", comment: "Button label removing a photo from the meal estimate"))
                                }
                        }
                    }
                }
            }
        }
    }

    /// Takes a photo or picks some from the library, up to what one message may carry.
    private var photoButton: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(action: { photoSource = .camera }) {
                    Label(String(localized: "Take Photo", table: "MealEstimate", comment: "Menu item taking a photo of the meal for the meal estimate"), systemImage: "camera")
                }
            }
            Button(action: { photoSource = .library }) {
                Label(String(localized: "Choose Photos", table: "MealEstimate", comment: "Menu item choosing photos of the meal for the meal estimate"), systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 19))
                .foregroundColor(model.canAddPhoto ? .secondary : Color(.tertiaryLabel))
                .frame(width: 30, height: 30)
        }
        .disabled(!model.canAddPhoto)
        .accessibilityLabel(Text("Add photo of the meal", tableName: "MealEstimate", comment: "Button label adding a photo to the meal estimate"))
        .padding(.vertical, 5)
    }

    /// A rounded, chat-style field with the send button inside, centred on a single line and
    /// staying at the bottom as the text grows.
    private func promptField(_ placeholder: String, text: Binding<String>, isEnabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundColor(.accentColor)
                .frame(height: 40)

            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1 ... 5)
                .focused($isInputFocused)
                .padding(.vertical, 9)

            photoButton

            Button(action: {
                if model.isEstimating {
                    // Stops the estimate so the text can be corrected; the field gets the keyboard back.
                    model.cancel()
                    isInputFocused = true
                } else {
                    isInputFocused = false
                    action()
                }
            }) {
                if model.isEstimating {
                    ZStack {
                        ProgressView()
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                    }
                    .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(isEnabled ? .accentColor : Color(.tertiaryLabel))
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled && !model.isEstimating)
            .accessibilityLabel(model.isEstimating ? String(localized: "Stop estimate", table: "MealEstimate", comment: "Button label stopping the AI meal estimate so the description can be corrected") : accessibilityLabel)
            .padding(.vertical, 5)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    // MARK: - Result

    private func summary(for estimate: MealCarbEstimate) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FavoriteFoodEmojiTile(emoji: estimate.foodTypeEmoji, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                (Text(estimate.name).font(.headline) + Text(verbatim: "  ") + totals(for: estimate).font(.subheadline.monospacedDigit()).foregroundColor(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 10) {
                    confidenceLabel(estimate.confidence)

                    Button(action: { showsBreakdown.toggle() }) {
                        HStack(spacing: 3) {
                            Text(showsBreakdown
                                ? String(localized: "Hide calculation", table: "MealEstimate", comment: "Button hiding the item breakdown of a meal estimate")
                                : String(localized: "Show calculation", table: "MealEstimate", comment: "Button showing the item breakdown of a meal estimate"))
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showsBreakdown ? 180 : 0))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Spacer(minLength: 0)

            Button(action: {
                isInputFocused = false
                showsBreakdown = false
                model.clear()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Start over", tableName: "MealEstimate", comment: "Button label clearing the meal estimate on the carb screen"))
        }
    }

    private func breakdown(for estimate: MealCarbEstimate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(estimate.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.food)
                            .font(.subheadline)
                        Text(item.amount)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(MealEstimateText.grams(item.carbsGrams))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if !estimate.assumptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(estimate.assumptions, id: \.self) { assumption in
                        Text(assumption)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
            }
        }
        .padding(.leading, 56)
    }

    private func confidenceLabel(_ confidence: MealCarbEstimate.Confidence) -> some View {
        let (title, color): (String, Color) = {
            switch confidence {
            case .high:
                return (String(localized: "Sure", table: "MealEstimate", comment: "Meal estimate confidence: high"), .green)
            case .medium:
                return (String(localized: "Fairly sure", table: "MealEstimate", comment: "Meal estimate confidence: medium"), .orange)
            case .low:
                return (String(localized: "Unsure", table: "MealEstimate", comment: "Meal estimate confidence: low"), .red)
            }
        }()
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// "45 g · 3 hr", and how many photos the estimate looked at, when it had any.
    private func totals(for estimate: MealCarbEstimate) -> Text {
        let text = Text(verbatim: "\(MealEstimateText.grams(estimate.roundedCarbs)) · \(MealEstimateText.duration(estimate.absorptionTime))")
        let photos = model.estimatePhotoCount
        guard photos > 0 else { return text }
        return text + Text(verbatim: " · ") + Text(Image(systemName: "photo")) + Text(verbatim: " \(photos)")
    }
}

enum MealEstimateText {
    static func grams(_ value: Double) -> String {
        Localizer.formatToLocalizedString(value, maxFractionDigits: 1, minFractionDigits: 0) + " g"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: interval) ?? ""
    }
}

// MARK: - Photo pickers

/// The camera, for photographing the plate. Calls back once with the photo, and not at all when
/// the caregiver cancels.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// The photo library, for photos taken before the carb screen was opened. Needs no photo library
/// permission: the system picker hands over only what was chosen.
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let limit: Int
    let onPick: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(limit, 1)
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
            guard !providers.isEmpty else { return }

            // Keep the order they were picked in, whatever order they finish loading in.
            var images = [UIImage?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    DispatchQueue.main.async {
                        images[index] = object as? UIImage
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { [parent] in
                parent.onPick(images.compactMap { $0 })
            }
        }
    }
}
