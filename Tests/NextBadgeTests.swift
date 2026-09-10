import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// Which ring wears NEXT.
///
/// The notch used to answer this by counting one place along the person's
/// rotation order, without asking whether that account could take a session.
/// On a real Mac that named a spent Claude as next while two healthy ones sat
/// behind it — and disagreed with the accounts window, in the same app, about
/// which subscription was about to be used. The account layer already walks the
/// queue properly, so the badge follows its answer and computes nothing.
@MainActor
final class NextBadgeTests: XCTestCase {
    private func account(_ label: String, at index: Int) -> ManagedAccount {
        ManagedAccount(id: UUID(), provider: .claude, label: label,
                       createdAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)))
    }

    /// The person's order is 4, 2, 3, 5, 6, 1. The Mac is on 6, so counting one
    /// place along lands on 1 — and 1 is spent. The account layer wraps past it
    /// to 4. The old code badged 1; the badge must now follow 4.
    func testTheBadgeFollowsWhoCanActuallyTakeOverNotWhoIsNextInLine() {
        let order = [4, 2, 3, 5, 6, 1].enumerated().map { account("Claude \($1)", at: $0) }
        let current = order[4]          // Claude 6
        let spent = order[5]            // Claude 1, next in line and finished
        let ready = order[0]            // Claude 4, where a switch would land

        let byOrder = AccountActivitySelection.queue(
            accounts: order, currentID: current.id, selectedID: current.id, next: .byOrder)
        XCTAssertEqual(byOrder[1].id, spent.id,
                       "Precondition: counting along the order really does land on the spent one")

        let decided = AccountActivitySelection.queue(
            accounts: order, currentID: current.id, selectedID: current.id,
            next: .decided(ready.id))
        XCTAssertEqual(decided[0].id, current.id)
        XCTAssertEqual(decided[1].id, ready.id, "NEXT did not follow the account layer")
        XCTAssertNotEqual(decided[1].id, spent.id, "NEXT landed on the spent account")
    }

    /// Nobody can take over. That is an answer, not a gap: the row keeps its
    /// NOW and shows no NEXT rather than badging whoever is drawn second.
    func testNoOneAbleToTakeOverMeansNoBadgeAtAll() {
        let order = (1...3).map { account("Claude \($0)", at: $0) }
        let decided = AccountActivitySelection.queue(
            accounts: order, currentID: order[0].id, selectedID: order[0].id,
            next: .decided(nil))
        XCTAssertEqual(decided.count, order.count, "Accounts went missing from the row")
        XCTAssertEqual(decided[0].id, order[0].id)
        // Nothing was promoted into second place, so no cell can claim NEXT.
        XCTAssertEqual(Set(decided.map(\.id)), Set(order.map(\.id)))
    }

    // MARK: - What is drawn

    private func item(_ name: String, id: UUID, usage: String,
                      current: Bool, next: Bool) -> NotchAccountItem {
        NotchAccountItem(id: id, name: name, subtitle: nil, usage: usage,
                         usedFraction: 0.4, isCurrent: current, isNext: next)
    }

    private func snapshot() -> ProviderSnapshot {
        ProviderSnapshot(id: "a", displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "s", label: "Session", usedFraction: 0.4)],
                         headlineID: "s")
    }

    private func render(_ items: [NotchAccountItem]) -> NSBitmapImageRep? {
        let picker = NotchAccountPicker(provider: .claude, snapshotID: "a",
                                        title: "Claude accounts", accounts: items)
        let view = InlineAccountRotation(picker: picker, snapshot: snapshot(), edge: .right,
                                         displayMode: .remaining, onChooseNext: { _ in })
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Ink per cell band, down a vertical edge.
    private func inkPerBand(_ rep: NSBitmapImageRep, bands: Int) -> [Int] {
        var counts = Array(repeating: 0, count: bands)
        let height = CGFloat(rep.pixelsHigh) / CGFloat(bands)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                let band = min(bands - 1, Int(CGFloat(y) / height))
                counts[band] += 1
            }
        }
        return counts
    }

    /// Ink in the gap between the first two cells, which is where the
    /// connector and nothing else is drawn.
    private func inkInHandoverGap(_ rep: NSBitmapImageRep) -> Int {
        // The stack is laid out in points and rendered at scale 1, so the two
        // agree. The gap starts one cell down and is a cell-spacing deep.
        let top = Int(NotchLayout.cellExtent)
        let bottom = min(rep.pixelsHigh, top + Int(NotchLayout.cellSpacing))
        guard top < bottom else { return 0 }
        var ink = 0
        for x in 0..<rep.pixelsWide {
            for y in top..<bottom where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.5 {
                ink += 1
            }
        }
        return ink
    }

    /// When nobody can take over, the picture has to go quiet as well as the
    /// label. A connector still running from the first cell to the second would
    /// say that account hands over to this one, while no cell claims to be
    /// next — the same contradiction the badge was fixed to remove.
    ///
    /// This is no longer a rare state: a rate-limited or stale reading counts
    /// as unknown rather than exhausted, so there are ordinary minutes with no
    /// usable successor at all.
    func testNoSuccessorMeansNoHandoverDrawnEither() throws {
        let ids = (0..<3).map { _ in UUID() }
        let names = ["Claude 6", "Claude 4", "Claude 1"]
        let withNext = (0..<3).map {
            item(names[$0], id: ids[$0], usage: "40%", current: $0 == 0, next: $0 == 1)
        }
        let none = (0..<3).map {
            item(names[$0], id: ids[$0], usage: "40%", current: $0 == 0, next: false)
        }
        XCTAssertTrue(InlineAccountRotation.drawsHandover(withNext))
        XCTAssertFalse(InlineAccountRotation.drawsHandover(none))

        let connected = try XCTUnwrap(render(withNext))
        let orphaned = try XCTUnwrap(render(none))
        XCTAssertGreaterThan(inkInHandoverGap(connected), 0,
                             "Precondition: the connector is drawn when there is a successor")
        XCTAssertEqual(inkInHandoverGap(orphaned), 0,
                       "A handover was drawn to an account that is not next")
    }

    /// The badge is painted where the data says, and nowhere else. Rendered twice
    /// and differenced, because the extra ink a badge adds is the only thing
    /// that reliably distinguishes one black cell from another.
    func testTheBadgeIsPaintedOnTheCellTheDataNames() throws {
        let ids = (0..<3).map { _ in UUID() }
        let bare = [
            item("Claude 6", id: ids[0], usage: "40%", current: true, next: false),
            item("Claude 4", id: ids[1], usage: "40%", current: false, next: false),
            item("Claude 1", id: ids[2], usage: "40%", current: false, next: false)
        ]
        var badged = bare
        badged[1] = item("Claude 4", id: ids[1], usage: "40%", current: false, next: true)

        let without = try XCTUnwrap(render(bare))
        let with = try XCTUnwrap(render(badged))
        let a = inkPerBand(without, bands: 3)
        let b = inkPerBand(with, bands: 3)

        XCTAssertGreaterThan(b[1], a[1], "No NEXT badge was painted on the named cell")
        // The spent account, last in the row, gains nothing.
        XCTAssertEqual(b[2], a[2], "Ink appeared on a cell that was never named NEXT")
    }
}
