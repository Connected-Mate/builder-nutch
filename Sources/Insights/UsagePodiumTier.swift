import Foundation
import SwiftUI

/// Presentation of existing lifetime thresholds. This never changes saved accounting.
enum UsagePodiumTier: Int, CaseIterable, Identifiable {
    case white, pearl, silver, gold, platinum, titanium, graphite, obsidian, black

    var id: Int { rawValue }
    var threshold: Int { rawValue == 0 ? 0 : UsageMilestoneProgress.thresholds[rawValue - 1] }
    var nameKey: String {
        ["White", "Pearl", "Silver", "Gold", "Platinum", "Titanium", "Graphite", "Obsidian", "Black"][rawValue]
    }
    var surfaceHex: UInt32 {
        [0xFAFAFA, 0xE7E7E7, 0xCDCDCD, 0xB9AD8C, 0xA2A6AA, 0x636970, 0x484B50, 0x24262A, 0x070808][rawValue]
    }
    var foregroundHex: UInt32 { rawValue <= 4 ? 0x242424 : 0xFAFAFA }
    var surface: Color { Color(hex: surfaceHex) }
    var foreground: Color { Color(hex: foregroundHex) }

    func name(locale: Locale) -> String {
        Self.localized(nameKey, locale: locale)
    }

    static func localized(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

struct UsagePodiumBadge: View {
    let tier: UsagePodiumTier

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(tier.rawValue)").monospacedDigit()
            Text(LocalizedStringKey(tier.nameKey))
        }
        .font(AppTheme.font(size: 11, weightValue: 650))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(tier.foreground)
        .background(UsagePodiumFinish(tier: tier, radius: 100))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// One finish for the saved-level badge and exported plate. The base palette
/// remains canonical; reflected light and recessed edges give it material depth.
/// No animation or window material: the PNG and its preview are identical.
struct UsagePodiumFinish: View {
    let tier: UsagePodiumTier
    var radius: CGFloat = 44
    private var light: Bool { tier.rawValue <= 4 }
    // Titanium is the lightest plate with light text. Its sheen comes from
    // darker bands, preserving readable contrast across the whole surface.
    private var reflection: Double { tier == .titanium ? 0.05 : 1 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(tier.surface)
            if tier == .titanium { shape.fill(.black.opacity(0.18)) }
            shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity(light ? 0.52 : 0.035 * reflection), location: 0),
                .init(color: .white.opacity(light ? 0.10 : 0.015 * reflection), location: 0.18),
                .init(color: .black.opacity(light ? 0.09 : 0.35), location: 0.44),
                .init(color: .black.opacity(light ? 0.02 : 0.12), location: 0.52),
                .init(color: .white.opacity(light ? 0.28 : 0.025 * reflection), location: 0.68),
                .init(color: .black.opacity(light ? 0.10 : 0.50), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            // A broad soft reflection sits away from the reading column.
            shape.fill(RadialGradient(colors: [.white.opacity(light ? 0.34 : 0.035 * reflection), .clear],
                                      center: .topTrailing, startRadius: 0, endRadius: 420))
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.8), location: 0),
                .init(color: .white.opacity(light ? 0.24 : 0.12), location: 0.30),
                .init(color: .black.opacity(0.55), location: 0.58),
                .init(color: .white.opacity(0.28), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
            shape.inset(by: 3).strokeBorder(LinearGradient(colors: [
                .white.opacity(light ? 0.45 : 0.08), .clear, .black.opacity(0.28)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
