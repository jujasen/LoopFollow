// LoopFollow
// AIBolusSuggestionCard.swift

import SwiftUI

/// Loop's open AI bolus suggestions on the main screen. «Se over» opens the bolus screen filled
/// in with the amount; nothing is sent until it is confirmed there.
struct AIBolusSuggestionCard: View {
    @ObservedObject var store = AIBolusSuggestionStore.shared
    @ObservedObject private var remoteType = Storage.shared.remoteType

    var body: some View {
        // Redrawn every half minute, so a lapsed suggestion goes away on time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let suggestions = store.visible(now: context.date)
            if !suggestions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        AIBolusSuggestionRow(suggestion: suggestion, canReview: remoteType.value == .loopAPNS)
                    }
                }
            }
        }
    }
}

private struct AIBolusSuggestionRow: View {
    let suggestion: AIBolusSuggestion
    let canReview: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AIBolusSuggestionText.title(suggestion))
                    .font(.subheadline.weight(.semibold))
                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(AIBolusSuggestionText.lapses(suggestion))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                if canReview {
                    Button(AIBolusSuggestionText.review) {
                        AIBolusSuggestionStore.shared.reviewing = suggestion
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(AIBolusSuggestionText.decline) {
                    withAnimation { AIBolusSuggestionStore.shared.dismiss(suggestion) }
                }
                .buttonStyle(.bordered)
            }
            .tint(.purple)
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.purple.opacity(0.16))
        )
    }
}
