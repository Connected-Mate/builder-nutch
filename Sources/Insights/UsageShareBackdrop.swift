import SwiftUI

/// The export keeps the app's black/neutral surfaces. Its only chromatic light
/// comes from the winning provider's existing official mark.
enum UsageSharePalette {
    static let black = Color(hex: 0x070808)
    static let edge = Color(hex: 0x555655)
    static let ink = AppTheme.ink
    static let muted = AppTheme.muted
    // Sampled from Assets.xcassets/brand-claude.imageset/claude.svg.
    static let claude = Color(hex: 0xD97757)

    static func accent(for provider: UsageTranscriptFormat?) -> Color {
        provider == .claude ? claude : edge
    }
}

/// All lights and texture are painted deterministically, so ImageRenderer and
/// the inline preview share the same canvas, with no native window materials.
struct UsageShareBackdrop: View {
    var provider: UsageTranscriptFormat? = nil
    private var accent: Color { UsageSharePalette.accent(for: provider) }

    var body: some View {
        ZStack {
            Color.black
            light(width: 650, height: 610, opacity: 0.48)
                .position(x: 1060, y: 255)
            light(width: 800, height: 260, opacity: 0.25)
                .rotationEffect(.degrees(-16)).position(x: 590, y: 540)
            light(width: 490, height: 400, opacity: 0.18)
                .position(x: 45, y: 160)
            texture
            LinearGradient(stops: [.init(color: .clear, location: 0.74),
                                   .init(color: .black.opacity(0.65), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: 1200, height: 630).clipped()
        .accessibilityHidden(true)
    }

    private func light(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(stops: [.init(color: accent.opacity(opacity), location: 0),
                                         .init(color: accent.opacity(opacity * 0.50), location: 0.45),
                                         .init(color: accent.opacity(0), location: 1)],
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
                                               y: CGFloat(row) * 28 + 3, width: 5, height: 5))
                }
            }
            context.fill(dots, with: .color(accent.opacity(0.22)))
            var grain = Path()
            var seed: UInt64 = 0xB017DE4
            for _ in 0..<15_000 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let x = CGFloat((seed >> 32) % 12_000) / 10
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let y = CGFloat((seed >> 32) % 6_300) / 10
                grain.addRect(CGRect(x: x, y: y, width: 0.65, height: 0.65))
            }
            context.fill(grain, with: .color(accent.opacity(0.13)))
        }
    }
}
