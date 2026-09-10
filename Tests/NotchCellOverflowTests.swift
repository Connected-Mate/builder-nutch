import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// Nothing drawn in a provider cell may be wider than the cell.
///
/// The shipped build printed the word "Usage unavailable short" under a ring,
/// in white, at percentage size. A percentage is four characters at the most
/// and fits by construction; a status word is as long as whatever language it
/// is written in, and that one ran clean out of the notch and over the desktop.
/// The rule now is that a cell shows a number or nothing, and the reason lives
/// in the hover card, which has room for a sentence.
@MainActor
final class NotchCellOverflowTests: XCTestCase {
    private func unavailable(id: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: "A provider with a very long name indeed",
            glyph: .claude, fidelity: .official,
            status: .error("The saved login expired or was revoked and needs a fresh sign-in."),
            windows: [],
            headlineID: nil
        )
    }

    private func item(_ name: String, usage: String, current: Bool, next: Bool,
                      broken: Bool) -> NotchAccountItem {
        NotchAccountItem(id: UUID(), name: name, subtitle: nil, usage: usage,
                         usedFraction: broken ? nil : 0.42,
                         isCurrent: current, isNext: next, needsAttention: broken)
    }

    /// The width a view actually wants, which is the thing at issue.
    ///
    /// Deliberately measured outside the notch. Inside it the cells sit under
    /// `clipShape`, so an over-wide label is cut off mid-word rather than
    /// painted onto the desktop — which is still broken, just broken quietly.
    /// Rendering the cell on its own is the only way to see the size it was
    /// asking for.
    private func intrinsicWidth<V: View>(_ view: V) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage.map { CGFloat($0.width) } ?? 0
    }

    /// What a cell may occupy across the stack: the notch's own body depth.
    /// Anything wider has to be clipped, and a clipped word is not a word.
    private var budget: CGFloat { NotchLayout.bodyDepth(for: .right) }

    /// The guard has teeth: the string that shipped really does blow the budget.
    /// Without this the test below would pass for a version that still printed
    /// it, and prove nothing at all.
    func testTheStringThatShippedWouldStillFailThisTest() {
        let offending = Text(verbatim: "Usage unavailable short")
            .font(Typography.percent)
            .fixedSize(horizontal: true, vertical: false)
        XCTAssertGreaterThan(intrinsicWidth(offending), budget,
                             "The control no longer overflows, so this test guards nothing")
    }

    func testNoCellIsEverWiderThanTheNotch() {
        // A broken account, which is the case that shipped wrong.
        XCTAssertLessThanOrEqual(
            intrinsicWidth(ProviderCell(snapshot: unavailable(id: "a"), needsAttention: true)),
            budget, "A broken provider cell is wider than the notch")

        // And an unread one, which prints a dash.
        XCTAssertLessThanOrEqual(
            intrinsicWidth(ProviderCell(snapshot: unavailable(id: "a"), needsAttention: false)),
            budget, "An unread provider cell is wider than the notch")

        // Every rotation cell, including the NOW and NEXT badges, whose words
        // are longer in French than in English.
        for edge in NotchEdge.allCases {
            let picker = NotchAccountPicker(
                provider: .claude, snapshotID: "a", title: "Claude accounts",
                accounts: [
                    item("Claude 1", usage: "70%", current: true, next: false, broken: false),
                    item("Claude 2", usage: "—", current: false, next: true, broken: true),
                    item("Claude 3", usage: "100%", current: false, next: false, broken: false)
                ]
            )
            let rotation = InlineAccountRotation(
                picker: picker, snapshot: unavailable(id: "a"), edge: edge,
                displayMode: .remaining, onChooseNext: { _ in }
            )
            let width = intrinsicWidth(rotation)
            if edge.isVertical {
                XCTAssertLessThanOrEqual(width, budget,
                    "The rotation stack is wider than the notch on \(edge)")
            } else {
                // Turned on its side the stack runs *along* the edge, so its
                // width is the whole row. Its depth is what must fit, and that
                // is what the cell height answers for.
                XCTAssertGreaterThan(width, 0)
            }
        }
    }

    /// The direct statement of the rule, without a renderer in the way.
    func testARotationCellShowsANumberOrNothing() {
        XCTAssertEqual(
            InlineAccountRotation.label(for: item("Claude 2", usage: "—",
                                                 current: false, next: true, broken: true)),
            "", "An unavailable account still printed a word"
        )
        XCTAssertEqual(
            InlineAccountRotation.label(for: item("Claude 1", usage: "70% left",
                                                 current: true, next: false, broken: false)),
            "70%"
        )
    }

    /// A broken account's last reading is no longer true of it, so the arc goes
    /// as well as the label. What is left is a red mark and a dim track.
    func testABrokenAccountShowsNoNumberAtAll() {
        let cell = ProviderCell(snapshot: unavailable(id: "a"), needsAttention: true)
        XCTAssertEqual(cell.percentTextForTesting, "")

        let unknown = ProviderCell(snapshot: unavailable(id: "a"), needsAttention: false)
        XCTAssertEqual(unknown.percentTextForTesting, "—",
                       "An unread account is unknown, not broken")
    }

    /// Being unread is not being broken. A profile that is connected and simply
    /// has not been used yet must not wear the alarm colour.
    func testOnlyTheNamedAccountGoesRed() {
        let model = NotchViewModel()
        let account = UUID()
        model.snapshots = [unavailable(id: account.uuidString), unavailable(id: "other")]
        model.attention = NotchAlert(id: "reconnect", title: "t", detail: "d",
                                     raisedAt: Date(), accountID: account)
        XCTAssertTrue(model.needsAttention(snapshotID: account.uuidString))
        XCTAssertFalse(model.needsAttention(snapshotID: "other"))

        // A problem belonging to no single account colours the notch, not every
        // logo inside it.
        model.attention = NotchAlert(id: "queueEmpty", title: "t", detail: "d",
                                     raisedAt: Date(), accountID: nil)
        XCTAssertFalse(model.needsAttention(snapshotID: account.uuidString))
        XCTAssertFalse(model.needsAttention(snapshotID: "other"))
    }
}
