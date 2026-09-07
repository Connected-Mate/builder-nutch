import AppKit
import XCTest
@testable import Codenotch

@MainActor
final class NotchClickDetailsTests: XCTestCase {
    private func globalPoint(_ controller: NotchWindowController, index: Int, across: CGFloat? = nil) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let model = controller.model
        let local = NotchPlacement(edge: model.edge, panelSize: frame.size).point(
            along: model.slack + model.ringCenter(index: index),
            across: across ?? (model.contentInset + NotchLayout.bodyDepth(for: model.edge) / 2))
        return CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)
    }

    func testHoverNeverOpensOrSwitchesDetailsAndClicksToggleOnEveryEdge() throws {
        var pointer = CGPoint.zero
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = (0..<2).map {
            ProviderSnapshot(id: "p\($0)", displayName: "Provider \($0)", glyph: .claude,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.4)])
        }
        var refreshes: [String] = []
        controller.onRefreshProvider = { refreshes.append($0) }
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }
        for edge in NotchEdge.allCases {
            controller.apply(.autoHide)
            controller.apply(edge: edge)
            controller.apply(.alwaysShow)
            pointer = try globalPoint(controller, index: 0)
            controller.pollCursorForTesting()
            XCTAssertNil(controller.model.selectedIndex, "Hover opened details on \(edge)")
            controller.handleClick()
            XCTAssertEqual(controller.model.selectedIndex, 0)
            let count = refreshes.count
            pointer = try globalPoint(controller, index: 1)
            controller.pollCursorForTesting()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(controller.model.selectedIndex, 0, "Hover changed clicked details")
            XCTAssertEqual(refreshes.count, count, "Hover refreshed a provider")
            controller.handleClick()
            XCTAssertEqual(controller.model.selectedIndex, 1)
            controller.handleClick()
            XCTAssertNil(controller.model.selectedIndex, "Second click should close")
            XCTAssertEqual(refreshes.count, count + 1, "Closing details should not refresh")
            controller.toggleDetails(index: 0)
            pointer = try globalPoint(controller, index: 0,
                across: controller.model.contentInset + NotchLayout.bodyDepth(for: edge) + NotchLayout.tailGap + NotchLayout.tailLength + 10)
            controller.pollCursorForTesting()
            controller.handleClick()
            XCTAssertEqual(controller.model.selectedIndex, 0, "Card interaction dismissed it")
            XCTAssertFalse(controller.model.isPinned, "Card click changed pin state")
            pointer = CGPoint(x: -100000, y: -100000)
            controller.dismissDetailsIfOutside()
            XCTAssertNil(controller.model.selectedIndex, "Outside click failed to dismiss")
            controller.model.onToggleDetails?(1)
            XCTAssertEqual(controller.model.selectedIndex, 1, "Accessibility action did not open details")
            controller.apply(.onHover)
            XCTAssertNil(controller.model.selectedIndex, "Folding retained details")
        }
    }

    func testProviderChangesDismissDetailsButUsageRefreshKeepsSelection() throws {
        let controller = NotchWindowController(cursorLocation: { CGPoint(x: -100000, y: -100000) })
        func snapshot(_ id: String, used: Double = 0.4) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "Session", usedFraction: used)])
        }
        controller.model.snapshots = [snapshot("a"), snapshot("b")]
        controller.show()
        controller.apply(.alwaysShow)
        defer { controller.apply(.hidden); controller.stop() }
        controller.toggleDetails(index: 1)
        controller.model.snapshots = [snapshot("a", used: 0.6), snapshot("b", used: 0.8)]
        XCTAssertEqual(controller.model.selectedIndex, 1)
        controller.model.snapshots = [snapshot("a"), snapshot("c")]
        XCTAssertNil(controller.model.selectedIndex, "Replacing an ID silently changed the open details")
        controller.toggleDetails(index: 1)
        controller.model.snapshots = [snapshot("c")]
        XCTAssertNil(controller.model.selectedIndex, "Removing an earlier provider kept the old index")
    }

    func testRealPanelMouseEventOpensDetails() throws {
        var pointer = CGPoint.zero
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = [ProviderSnapshot(id: "p", displayName: "Provider", glyph: .claude,
            fidelity: .official, status: .ok, windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.4)])]
        controller.show()
        controller.apply(.alwaysShow)
        defer { controller.apply(.hidden); controller.stop() }
        pointer = try globalPoint(controller, index: 0)
        controller.pollCursorForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let window = try XCTUnwrap(controller.panelContentViewForTesting?.window)
        let location = window.convertPoint(fromScreen: pointer)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        XCTAssertEqual(controller.model.selectedIndex, 0, "The native responder chain lost the ring click")
    }
}
