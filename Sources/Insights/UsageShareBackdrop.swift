import SwiftUI

/// Export-only colors sampled from the user's luminous reference. These do not
/// change the compact manager or the notch's neutral palette.
enum UsageSharePalette {
    static let black = Color(hex: 0x070808)
    static let edge = Color(hex: 0x555655)
    static let ink = AppTheme.ink
    static let muted = Color(hex: 0x9C9D9E)
    static let paper = Color(hex: 0xFFFCF7)
    static let coral = Color(hex: 0xFFC094)
    static let lavender = Color(hex: 0xC8A4FF)
    static let mint = Color(hex: 0x9BDDD1)
    static let gold = Color(hex: 0xFFE235)
    static let amber = Color(hex: 0xFFAC32)
    static let blue = Color(hex: 0x789BD7)
    static let forest = Color(hex: 0x15180E)
}

/// Painted light, rather than a system material, makes the same artwork render
/// in the live preview and in an offline ImageRenderer export.
struct UsageShareBackdrop: View {
    var body: some View {
        ZStack {
            UsageSharePalette.forest
            light(UsageSharePalette.blue, width: 690, height: 780, opacity: 0.95)
                .rotationEffect(.degrees(-24)).position(x: 65, y: 352)
            light(UsageSharePalette.lavender, width: 550, height: 360, opacity: 0.55)
                .rotationEffect(.degrees(15)).position(x: 210, y: 657)
            light(UsageSharePalette.amber, width: 790, height: 940, opacity: 1)
                .rotationEffect(.degrees(-22)).position(x: 1098, y: 98)
            light(UsageSharePalette.coral, width: 440, height: 410, opacity: 0.95)
                .position(x: 1100, y: 12)
            light(UsageSharePalette.gold, width: 610, height: 255, opacity: 0.77)
                .rotationEffect(.degrees(-27)).position(x: 600, y: 536)
            light(UsageSharePalette.amber, width: 730, height: 240, opacity: 0.85)
                .rotationEffect(.degrees(-30)).position(x: 770, y: 470)
            light(UsageSharePalette.gold, width: 340, height: 390, opacity: 0.25)
                .position(x: 508, y: -97)
            texture
            // A gentle vignette retains contrast around the source caption.
            LinearGradient(stops: [.init(color: .clear, location: 0.78),
                                   .init(color: .black.opacity(0.24), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: 1200, height: 630).clipped()
        .accessibilityHidden(true)
    }

    private func light(_ color: Color, width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(stops: [.init(color: color.opacity(opacity), location: 0),
                                         .init(color: color.opacity(opacity * 0.84), location: 0.25),
                                         .init(color: color.opacity(opacity * 0.34), location: 0.61),
                                         .init(color: color.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: max(width, height) / 2))
            .frame(width: width, height: height)
            .blur(radius: 24)
    }

    private var texture: some View {
        Canvas { context, _ in
            var dots = Path()
            for row in 0...23 {
                for column in 0...43 {
                    dots.addEllipse(in: CGRect(x: CGFloat(column) * 28 - 2,
                                               y: CGFloat(row) * 28 + 3, width: 8, height: 8))
                }
            }
            context.fill(dots, with: .color(.white.opacity(0.21)))

            // Fine, deterministic grain avoids shimmer between preview and PNG.
            var grain = Path()
            var seed: UInt64 = 0xB017DE4
            for _ in 0..<15_000 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let x = CGFloat((seed >> 32) % 12_000) / 10
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let y = CGFloat((seed >> 32) % 6_300) / 10
                grain.addRect(CGRect(x: x, y: y, width: 0.65, height: 0.65))
            }
            context.fill(grain, with: .color(.white.opacity(0.11)))
        }
    }
}
