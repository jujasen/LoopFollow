// LoopFollow
// HomeCardStyle.swift

import SwiftUI

/// The rounded card every block on Home sits on, as in Loop and the iOS
/// grouped lists: a raised surface on the grouped background, light and dark.
struct HomeCard: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func homeCard(padding: CGFloat = 12) -> some View {
        modifier(HomeCard(padding: padding))
    }
}

/// Tints for labels and icons. The system colours are too light to read as text
/// on white, so light mode gets a darker shade of the same hue.
enum HomePalette {
    static let insulin = adaptive(light: UIColor(red: 0.70, green: 0.31, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let carbs = adaptive(light: UIColor(red: 0.11, green: 0.50, blue: 0.22, alpha: 1), dark: .systemGreen)
    static let basal = adaptive(light: UIColor(red: 0.12, green: 0.37, blue: 0.82, alpha: 1), dark: UIColor(red: 0.39, green: 0.62, blue: 1.00, alpha: 1))
    static let prediction = adaptive(light: UIColor(red: 0.43, green: 0.25, blue: 0.85, alpha: 1), dark: UIColor(red: 0.69, green: 0.55, blue: 1.00, alpha: 1))
    static let warning = adaptive(light: UIColor(red: 0.70, green: 0.31, blue: 0.00, alpha: 1), dark: .systemOrange)
    /// The chosen segment of a segmented control, as UIKit draws it.
    static let selectedSegment = adaptive(light: .white, dark: .systemGray3)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// A white SF Symbol on a rounded, tinted square, like the icons in iOS Settings.
struct TintedIconSquare: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint))
            .accessibilityHidden(true)
    }
}

/// Loop's status ring: a thick circle coloured by how fresh the last loop run is.
/// An open loop (closed loop switched off in Loop) leaves a gap at the top, as in Loop.
struct LoopRingView: View {
    let freshness: LoopFreshness
    var isOpenLoop: Bool = false
    var lineWidth: CGFloat = 6

    var body: some View {
        Circle()
            .trim(from: isOpenLoop ? 0.08 : 0, to: isOpenLoop ? 0.92 : 1)
            .rotation(.degrees(-90))
            .stroke(freshness.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .padding(lineWidth / 2)
    }
}

/// A short coloured stripe at the leading edge of a card, telling the kinds of
/// suggestion cards apart (low watch, AI) without filling the whole card with colour.
struct HomeCardAccent: View {
    let color: Color

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 4)
            .padding(.vertical, 10)
            .padding(.leading, 3)
            .accessibilityHidden(true)
    }
}
