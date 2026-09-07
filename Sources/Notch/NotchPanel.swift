import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at your
/// usage must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first — the hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onDragEnded: ((NSPoint, NSPoint) -> Void)?
    var isLeftButtonPressed: () -> Bool = {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
    private var longPressWork: DispatchWorkItem?
    private var mouseDownLocation: NSPoint?
    private var didDrag = false
    private var didLongPress = false

    override func sendEvent(_ event: NSEvent) {
        let overChrome = contentView?.hitTest(event.locationInWindow) != nil
        switch event.type {
        case .rightMouseDown where overChrome:
            guard let menu = contextMenuProvider?(), let view = contentView else {
                return super.sendEvent(event)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        case .leftMouseDown where overChrome:
            mouseDownLocation = event.locationInWindow
            didDrag = false
            didLongPress = false
            longPressWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.longPressWork = nil
                guard self.isLeftButtonPressed() else { return }
                self.didLongPress = true
                self.onLongPress?()
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48, execute: work)
        case .leftMouseDragged:
            if let origin = mouseDownLocation,
               hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 7 {
                didDrag = true
                cancelLongPress(resetGesture: false)
            }
        case .leftMouseUp:
            let origin = mouseDownLocation
            let dragged = didDrag
            let held = didLongPress
            cancelLongPress(resetGesture: false)
            if dragged, let origin {
                onDragEnded?(origin, event.locationInWindow)
            } else if !held {
                onClick?()
            }
            mouseDownLocation = nil
            didDrag = false
            didLongPress = false
        default:
            break
        }
        super.sendEvent(event)
    }

    private func cancelLongPress(resetGesture: Bool = true) {
        longPressWork?.cancel()
        longPressWork = nil
        if resetGesture { mouseDownLocation = nil }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
