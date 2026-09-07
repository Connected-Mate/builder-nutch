import AppKit
import CoreText
import SwiftUI

/// Shared with the approved website. The ambient notch has its own dark palette.
enum AppTheme {
    static let paper = Color(hex: 0xFAFAFA)
    static let surface = Color.white
    static let ink = Color(hex: 0x242424)
    static let muted = Color(hex: 0x626262)
    static let line = Color(hex: 0xE3E3E3)
    static let soft = Color(hex: 0xF3F3F3)
    static let sidebar = Color(hex: 0xFCFCFC)
    static let selected = Color(hex: 0xEEEEEE)
    static let track = Color(hex: 0xE7E7E7)
    static let windowBackground = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)

    /// Registered only inside this application, without installing a system font.
    static let fontName: String? = {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
        return name
    }()

    static func registerFonts() { _ = fontName }

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 32
        case .title: size = 26
        case .title2: size = 22
        case .title3: size = 18
        case .headline, .body: size = 14
        case .callout: size = 13
        case .subheadline: size = 12
        case .footnote, .caption: size = 11
        case .caption2: size = 10
        default: size = 14
        }
        return font(size: size, weight: weight)
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard fontName != nil else { return .system(size: size, weight: weight) }
        let axisWeight: Double
        switch weight {
        case .ultraLight: axisWeight = 200
        case .thin, .light: axisWeight = 300
        case .medium: axisWeight = 500
        case .semibold: axisWeight = 600
        case .bold: axisWeight = 700
        case .heavy, .black: axisWeight = 800
        default: axisWeight = 400
        }
        return font(size: size, weightValue: axisWeight)
    }

    /// The website uses intermediate variable weights (550 and 650).
    /// Keep those exact weights when translating its product components.
    static func font(size: CGFloat, weightValue: Double) -> Font {
        guard let fontName else { return .system(size: size) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: fontName,
            kCTFontVariationAttribute: [
                NSNumber(value: 0x77676874): min(max(weightValue, 200), 800), // wght
                NSNumber(value: 0x77647468): 100,        // wdth
                NSNumber(value: 0x6F70737A): min(max(Double(size), 12), 96) // opsz
            ]
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

struct AppButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 32 : 38)
            .foregroundStyle(primary ? AppTheme.surface : AppTheme.ink)
            .background(primary ? AppTheme.ink : (isHovered ? AppTheme.soft : AppTheme.surface),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? AppTheme.ink : AppTheme.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
    }
}

/// Quiet decorative dots; never intercepts clicks or appears in VoiceOver.
struct AppDotBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: CGFloat(8), to: size.width, by: 18) {
                for y in stride(from: CGFloat(8), to: size.height, by: 18) {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.fill(path, with: .color(AppTheme.muted.opacity(0.12)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
