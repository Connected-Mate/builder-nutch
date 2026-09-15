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
        .background(tier.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.muted.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
