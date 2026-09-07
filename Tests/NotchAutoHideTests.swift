import AppKit
import XCTest
@testable import Codenotch

final class NotchRevealGeometryTests: XCTestCase {
    func testStoredValuesRemainCompatibleAndModesAreDistinct() {
        XCTAssertEqual(NotchVisibility(rawValue: "hidden"), .hidden)
        XCTAssertEqual(NotchVisibility(rawValue: "onHover"), .onHover)
        XCTAssertEqual(NotchVisibility(rawValue: "alwaysShow"), .alwaysShow)
        XCTAssertEqual(NotchVisibility.autoHide.rawValue, "autoHide")
        XCTAssertEqual(NotchVisibility.autoHide.title, "Auto-hide")
        XCTAssertEqual(NotchVisibility.hidden.title, "Off")
    }
}

@MainActor
final class NotchAutoHideTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func handlePoint(_ controller: NotchWindowController, alongOffset: CGFloat = 0,
                             depth: CGFloat? = nil) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let model = controller.model
        let local = NotchPlacement(edge: model.edge, panelSize: frame.size).point(
            along: model.slack + model.shapeLength / 2 + alongOffset,
            across: depth ?? model.restingDepth / 2)
        return CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)
    }

    func testOnlyTheSmallHandleRevealsInBothModesOnEveryEdge() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        let away = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        var pointer = away
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.apply(.autoHide)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        for edge in NotchEdge.allCases {
            for mode in [NotchVisibility.autoHide, .onHover] {
                pointer = away
                controller.apply(.autoHide)
                controller.apply(edge: edge)
                controller.apply(mode)
                XCTAssertFalse(controller.model.isExpanded)
                XCTAssertEqual(controller.panelVisibleForTesting, mode == .onHover)
                XCTAssertTrue(controller.panelIgnoresMouseForTesting)
                if mode == .autoHide {
                    controller.handleClick()
                    XCTAssertFalse(controller.model.isExpanded, "An invisible region accepted a click")
                }
                // One point beyond either end or the inner face must not wake it.
                for offset in [-1.0, 1.0] {
                    pointer = try handlePoint(controller, alongOffset: offset * (controller.model.restingLength / 2 + 1))
                    controller.pollCursorForTesting()
                    XCTAssertFalse(controller.model.isExpanded, "Outside handle end: \(edge) \(mode)")
                }
                pointer = try handlePoint(controller, depth: controller.model.restingDepth + 1)
                controller.pollCursorForTesting()
                XCTAssertFalse(controller.model.isExpanded, "Generous old hit region still wakes it")
                // Unrelated parts of the physical edge stay inactive, including Dock/menu bar edges.
                for fraction in [0.1, 0.9] {
                    switch edge {
                    case .left: pointer = CGPoint(x: screen.frame.minX, y: screen.frame.minY + screen.frame.height * fraction)
                    case .right: pointer = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.minY + screen.frame.height * fraction)
                    case .top: pointer = CGPoint(x: screen.frame.minX + screen.frame.width * fraction, y: screen.frame.maxY - 1)
                    case .bottom: pointer = CGPoint(x: screen.frame.minX + screen.frame.width * fraction, y: screen.frame.minY)
                    }
                    controller.pollCursorForTesting()
                    XCTAssertFalse(controller.model.isExpanded, "Unrelated edge revealed: \(edge) \(mode)")
                }
                pointer = try handlePoint(controller)
                controller.pollCursorForTesting()
                XCTAssertTrue(controller.model.isExpanded, "Handle failed to reveal: \(edge) \(mode)")
                XCTAssertTrue(controller.panelVisibleForTesting)
                XCTAssertNil(controller.model.selectedIndex)
                pointer = away
                controller.pollCursorForTesting()
                pump(0.15)
                XCTAssertTrue(controller.model.isExpanded, "Folded before the grace elapsed")
                pump(0.5)
                XCTAssertFalse(controller.model.isExpanded)
                XCTAssertEqual(controller.panelVisibleForTesting, mode == .onHover)
                XCTAssertTrue(controller.panelIgnoresMouseForTesting)
            }
        }
    }

    func testOffNeverRevealsAndModeChangesCancelStaleFolds() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        var pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        pointer = try handlePoint(controller)
        controller.apply(.hidden)
        controller.pollCursorForTesting()
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.panelVisibleForTesting)
        XCTAssertTrue(controller.panelIgnoresMouseForTesting)
        controller.apply(.autoHide)
        controller.pollCursorForTesting()
        XCTAssertTrue(controller.model.isExpanded)
        pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        controller.pollCursorForTesting()
        controller.apply(.alwaysShow)
        pump(0.65)
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertTrue(controller.panelVisibleForTesting)
        controller.apply(.onHover)
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertTrue(controller.panelVisibleForTesting)
    }

    func testMovingAutoHiddenNotchDoesNotFlashOrReopenFromOldHandle() throws {
        var pointer = CGPoint.zero
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        pointer = try handlePoint(controller)
        controller.apply(.autoHide)
        controller.pollCursorForTesting()
        XCTAssertTrue(controller.model.isExpanded)
        controller.apply(edge: .left)
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.panelVisibleForTesting)
        controller.pollCursorForTesting()
        pump(0.65)
        XCTAssertFalse(controller.model.isExpanded)
        pointer = try handlePoint(controller)
        controller.pollCursorForTesting()
        XCTAssertTrue(controller.panelVisibleForTesting)
    }

    func testChangingModeDuringEdgeAnimationCannotResurrectHiddenNotch() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        let controller = NotchWindowController(cursorLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) })
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        controller.apply(.alwaysShow)
        controller.apply(edge: .left)
        controller.apply(.autoHide)
        pump(0.8)
        XCTAssertEqual(controller.model.edge, .left)
        XCTAssertFalse(controller.panelVisibleForTesting)
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertTrue(controller.panelIgnoresMouseForTesting)
    }
}
