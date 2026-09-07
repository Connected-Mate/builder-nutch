import Foundation

/// How much of itself the notch shows when you are not using it.
///
/// The visible pill and its invisible counterpart share one small reveal region. Stored
/// raw values stay compatible with earlier versions.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open. The readings are always on screen.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it. The default.
    case onHover
    /// Invisible at rest; reaching the resting handle’s position opens the notch.
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
            return "Hover over the small handle to open the notch. Click a provider for its details."
        case .autoHide:
            return "Hidden at rest. Hover over the small handle’s position to reveal the notch; the rest of the screen edge stays inactive."
        case .hidden:
            // Said here because a hidden notch is also a hidden way back in.
            return "Nothing on screen. Open Builder Nutch again from Applications "
                 + "to bring these settings back."
        }
    }
}
