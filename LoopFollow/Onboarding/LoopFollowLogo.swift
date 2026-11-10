// LoopFollow
// LoopFollowLogo.swift

import SwiftUI

/// The LoopFollow mark: the app icon's face (night sky, glowing ring with an arrow and a
/// glucose line), as a rounded square so it has real visual mass when tilted in 3D.
/// The picture is LoopFollowMark in the asset catalog, made from loopfollow-icon.svg.
struct LoopFollowLogo: View {
    var size: CGFloat = 120

    var body: some View {
        Image("LoopFollowMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// LoopFollow logo that lands like a coin: it starts edge-on (rotated 90° about
/// the vertical axis) and springs open to face the viewer, overshooting a little
/// past flat and rocking back to rest. Respects Reduce Motion by rendering flat.
struct AnimatedLoopFollowLogo: View {
    var size: CGFloat = 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 90

    var body: some View {
        LoopFollowLogo(size: size)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.7
            )
            // Grounding shadow so the landing reads as dimensional.
            .shadow(color: .black.opacity(0.28), radius: size * 0.08, x: 0, y: size * 0.06)
            .onAppear {
                if reduceMotion {
                    angle = 0
                } else {
                    withAnimation(.spring(response: 0.85, dampingFraction: 0.5).delay(0.15)) {
                        angle = 0
                    }
                }
            }
    }
}
