import AppKit
import XCTest
@testable import Codenotch

final class NotchRevealGeometryTests: XCTestCase {
    func testAllPhysicalEdgesOnAnOffsetDisplay() {
        let screen = CGRect(x: -1600, y: -200, width: 1600, height: 1000)
        let positions: [(NotchEdge, CGPoint)] = [
            (.left, CGPoint(x: screen.minX, y: screen.midY)),
            (.right, CGPoint(x: screen.maxX - 1, y: screen.midY)),
            (.top, CGPoint(x: screen.midX, y: screen.maxY - 1)),
            (.bottom, CGPoint(x: screen.midX, y: screen.minY))
        ]
        for (edge, point) in positions {
            XCTAssertTrue(NotchGeometry.isAtRevealEdge(point, screenFrame: screen, edge: edge), "\(edge)")
            XCTAssertFalse(NotchGeometry.isAtRevealEdge(CGPoint(x: screen.midX, y: screen.midY), screenFrame: screen, edge: edge))
        }
        XCTAssertFalse(NotchGeometry.isAtRevealEdge(CGPoint(x: screen.minX - 1, y: screen.midY), screenFrame: screen, edge: .left))
        XCTAssertFalse(NotchGeometry.isAtRevealEdge(CGPoint(x: screen.minX, y: screen.maxY + 1), screenFrame: screen, edge: .left))
        XCTAssertFalse(NotchGeometry.isAtRevealEdge(CGPoint(x: screen.minX + 3, y: screen.midY), screenFrame: screen, edge: .left))
    }

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

    func testInvisiblePanelRevealsAndFoldsOnEveryEdgeWithoutTakingHiddenClicks() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        var pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.apply(.autoHide)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        for edge in NotchEdge.allCases {
            controller.apply(edge: edge)
            controller.apply(.autoHide)
            XCTAssertFalse(controller.panelVisibleForTesting, "A resting pill appeared on \(edge)")
            XCTAssertTrue(controller.panelIgnoresMouseForTesting)
            controller.handleClick()
            XCTAssertFalse(controller.model.isExpanded, "An invisible region accepted a click")
            switch edge {
            case .left: pointer = CGPoint(x: screen.frame.minX, y: screen.frame.midY)
            case .right: pointer = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.midY)
            case .top: pointer = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
            case .bottom: pointer = CGPoint(x: screen.frame.midX, y: screen.frame.minY)
            }
            controller.pollCursorForTesting()
            XCTAssertTrue(controller.model.isExpanded, "Did not reveal on \(edge)")
            XCTAssertTrue(controller.panelVisibleForTesting)
            pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            controller.pollCursorForTesting()
            pump(0.15)
            XCTAssertTrue(controller.model.isExpanded, "Folded before the existing grace elapsed")
            pump(0.5)
            XCTAssertFalse(controller.model.isExpanded, "Failed to fold on \(edge)")
            XCTAssertFalse(controller.panelVisibleForTesting)
            XCTAssertTrue(controller.panelIgnoresMouseForTesting)
        }
    }

    func testOffNeverRevealsAndModeChangesCancelStaleFolds() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        var pointer = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.midY)
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
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
        XCTAssertTrue(controller.panelVisibleForTesting, "The original visible pill disappeared")
    }

    func testMovingAutoHiddenNotchDoesNotFlashOrReopenFromOldEdge() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        var pointer = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.midY)
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        controller.apply(.autoHide)
        controller.pollCursorForTesting()
        XCTAssertTrue(controller.model.isExpanded)
        controller.apply(edge: .left)
        XCTAssertEqual(controller.model.edge, .left)
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.panelVisibleForTesting)
        controller.pollCursorForTesting()
        pump(0.65)
        XCTAssertFalse(controller.model.isExpanded)
        pointer = CGPoint(x: screen.frame.minX, y: screen.frame.midY)
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
