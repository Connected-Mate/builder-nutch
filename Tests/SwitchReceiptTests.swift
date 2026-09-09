import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// The receipt the notch shows when rotation moves the Mac login by itself.
///
/// It gained a line saying *why*. A switch nobody can explain reads as the app
/// helping itself rather than the person, and the limit that actually ran out
/// is usually not the one they were watching.
@MainActor
final class SwitchReceiptTests: XCTestCase {
    private let reason = "Claude 3 had 12% left on its Weekly limit."

    private func snapshot(id: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)],
            headlineID: "session"
        )
    }

    private func event(reason: String) -> AutomaticAccountSwitch {
        AutomaticAccountSwitch(
            provider: .claude, fromID: UUID(), fromName: "Claude 3",
            toID: UUID(), toName: "Claude 5", reason: reason
        )
    }

    /// The budget has to grow, or the sentence is drawn into a card that was
    /// measured without it and clipped off the bottom.
    func testTheCardMakesRoomForTheReason() {
        let bare = NotchLayout.automaticSwitchCardHeight(identitySubtitle: true)
        let explained = NotchLayout.automaticSwitchCardHeight(
            identitySubtitle: true, reason: reason)
        XCTAssertGreaterThan(explained, bare)

        // An empty reason is the old card exactly, so nothing that does not
        // carry one gains a gap where the sentence would have been.
        XCTAssertEqual(
            NotchLayout.automaticSwitchCardHeight(identitySubtitle: true, reason: ""),
            bare
        )
    }

    /// Capped, so a long sentence cannot push the handoff off the top of a
    /// card that is clipped rather than scrolled.
    func testAVeryLongReasonIsBounded() {
        let rambling = String(repeating: "This limit ran out a while ago. ", count: 40)
        let capped = NotchLayout.automaticSwitchCardHeight(
            identitySubtitle: true, reason: rambling)
        let twoLines = NotchLayout.automaticSwitchCardHeight(
            identitySubtitle: true, reason: reason)
        XCTAssertLessThanOrEqual(capped, twoLines + NotchLayout.cardBodyLineHeight)
    }

    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    private func render(_ card: TooltipCard) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: card.frame(width: 400, height: 400))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    func testTheReasonIsActuallyDrawn() throws {
        let snapshot = snapshot(id: "a")
        let silent = try XCTUnwrap(render(TooltipCard(
            snapshot: snapshot, automaticSwitch: event(reason: ""), now: Date()
        )))
        let explained = try XCTUnwrap(render(TooltipCard(
            snapshot: snapshot, automaticSwitch: event(reason: reason), now: Date()
        )))
        XCTAssertGreaterThan(inkedFraction(explained), inkedFraction(silent),
                             "The reason was measured for but never drawn")
    }
}
