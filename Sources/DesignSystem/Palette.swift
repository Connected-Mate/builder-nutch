import SwiftUI

/// Neutral ambient surface matching the website’s compact dark notch.
/// Usage amounts, labels and warning symbols carry state alongside tone.
enum Palette {
    static let notch         = Color.black                    // #000000
    static let card          = Color.black                    // #000000
    static let ringTrack     = Color(hex: 0x303030)
    static let barTrack      = Color(hex: 0x2D2D2D)

    static let ample         = Color.white                        // available
    static let watch         = Color(hex: 0xC8C8C8)               // watch
    static let critical      = Color(hex: 0xA8A8A8)               // low quota

    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: 0xAAAAAA)

    // MARK: - Attention

    // The one accent in the whole app, and the only colour in the notch that is
    // not a neutral. It earns that by being rare: these three appear when
    // something has stopped working and needs a hand, and at no other time. A
    // red that turns up every day stops meaning anything, which is the reason
    // usage bands stayed grey.
    //
    // Derived in OKLCH at a fixed hue of 27° so the steps are perceptually even
    // rather than evenly spaced sRGB numbers, and each one verified inside the
    // sRGB gamut rather than clipped into it.

    /// `oklch(0.22 0.090 27)` — the black's first blush. Near-black on purpose:
    /// the provider rings sit in this part of the gradient and their white
    /// glyphs have to stay legible against it.
    static let alertEmber = Color(hex: 0x3A0002)

    /// `oklch(0.42 0.165 27)` — the body turning over, below the rings.
    static let alertBlaze = Color(hex: 0x920A11)

    /// `oklch(0.58 0.215 27)` — the inner lip, and the only full-strength red.
    /// 4.8:1 against white and 4.4:1 against black, so it reads on a pale
    /// wallpaper and a dark one alike.
    static let alert      = Color(hex: 0xDD2729)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
