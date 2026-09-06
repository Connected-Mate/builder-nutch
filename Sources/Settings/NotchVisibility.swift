import Foundation

/// How much of itself the notch shows when you are not using it.
///
/// The original pill remains distinct from an invisible edge trigger. Stored
/// raw values stay compatible with earlier versions.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open. The readings are always on screen.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it. The default.
    case onHover
    /// Invisible at rest; reaching the selected screen edge opens the notch.
    case autoHide
    /// Off until the user changes the setting.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover:    return "Show on hover"
        case .autoHide:   return "Auto-hide"
        case .hidden:     return "Off"
        }
    }

    var explanation: String {
        switch self {
        case .alwaysShow:
            return "The notch stays open with every reading visible."
        case .onHover:
            return "A small pill at the screen edge that opens when you reach it."
        case .autoHide:
            return "Nothing visible at rest. Move the pointer to the selected screen edge to reveal the notch; move away to hide it again."
        case .hidden:
            // Said here because a hidden notch is also a hidden way back in.
            return "Nothing on screen. Open Builder Nutch again from Applications "
                 + "to bring these settings back."
        }
    }
}
