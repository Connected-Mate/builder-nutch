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
