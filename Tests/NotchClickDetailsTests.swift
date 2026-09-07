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
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(up)

        XCTAssertEqual(controller.model.selectedIndex, 0, "The native responder chain lost the ring click")
    }

    func testHoldingProviderExpandsItsAccountsInsideTheNotch() throws {
        var pointer = CGPoint.zero
        let current = UUID(), next = UUID(), later = UUID()
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = [ProviderSnapshot(
            id: current.uuidString, displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.4)]),
            ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                             fidelity: .official, status: .ok, windows: [])]
        controller.onAccountPicker = { snapshotID in
            NotchAccountPicker(provider: .claude, snapshotID: snapshotID, title: "Claude accounts", accounts: [
                NotchAccountItem(id: current, name: "Current", subtitle: nil, usage: "60% left", usedFraction: 0.4, isCurrent: true, isNext: false),
                NotchAccountItem(id: next, name: "Next", subtitle: nil, usage: "90% left", usedFraction: 0.1, isCurrent: false, isNext: true),
                NotchAccountItem(id: later, name: "Later", subtitle: nil, usage: "100% left", usedFraction: 0, isCurrent: false, isNext: false)
            ])
        }
        controller.show()
        controller.apply(.alwaysShow)
        defer { controller.apply(.hidden); controller.stop() }
        pointer = try globalPoint(controller, index: 0)
        controller.pollCursorForTesting()
        let window = try XCTUnwrap(controller.panelContentViewForTesting?.window)
        (window as? NotchPanel)?.isLeftButtonPressed = { true }
        let location = window.convertPoint(fromScreen: pointer)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(controller.model.accountPicker?.accounts.map(\.id), [current, next, later])
        XCTAssertEqual(controller.model.layoutCellCount, 3)
        XCTAssertNil(controller.model.selectedIndex, "Inline accounts must replace the detached detail card")
        XCTAssertTrue(controller.model.staysOpen)
        XCTAssertFalse(controller.model.isPinned)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(up)

        var moved: (UUID, UUID)?
        controller.model.onMoveAccount = { moved = ($0, $1) }
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        func dragLocation(_ visualIndex: Int) -> CGPoint {
            let topLeft = place.point(
                along: controller.model.slack
                    + NotchLayout.ringCenter(index: visualIndex, edge: controller.model.edge, flare: controller.model.flare)
                    + controller.model.endSpread,
                across: controller.model.contentInset + NotchLayout.bodyDepth(for: controller.model.edge) / 2)
            return CGPoint(x: topLeft.x, y: frame.height - topLeft.y)
        }
        let dragStart = dragLocation(2), dragEnd = dragLocation(1)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        window.sendEvent(try event(.leftMouseDown, dragStart, 3))
        window.sendEvent(try event(.leftMouseDragged, dragEnd, 4))
        window.sendEvent(try event(.leftMouseUp, dragEnd, 5))
        XCTAssertEqual(moved?.0, later)
        XCTAssertEqual(moved?.1, next)
        XCTAssertNil(controller.model.accountPicker, "A completed reorder should restore the provider list")
    }

    func testOutsideClickDismissesInlineAccountsAndFoldsTheNotch() throws {
        var pointer = CGPoint.zero
        let current = UUID(), next = UUID()
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = [ProviderSnapshot(
            id: current.uuidString, displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok, windows: [])]
        controller.onAccountPicker = { _ in
            NotchAccountPicker(provider: .claude, snapshotID: current.uuidString,
                title: "Claude accounts", accounts: [
                    NotchAccountItem(id: current, name: "Current", subtitle: nil,
                                     usage: "10% left", usedFraction: 0.9,
                                     isCurrent: true, isNext: false),
                    NotchAccountItem(id: next, name: "Next", subtitle: nil,
                                     usage: "100% left", usedFraction: 0,
                                     isCurrent: false, isNext: true)
                ])
        }
        controller.show()
        controller.apply(.onHover)
        defer { controller.apply(.hidden); controller.stop() }
        controller.handleClick()
        pointer = try globalPoint(controller, index: 0)
        controller.pollCursorForTesting()
        let window = try XCTUnwrap(controller.panelContentViewForTesting?.window)
        (window as? NotchPanel)?.isLeftButtonPressed = { true }
        let location = window.convertPoint(fromScreen: pointer)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1))
        window.sendEvent(down)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        XCTAssertNotNil(controller.model.accountPicker)

        pointer = CGPoint(x: -100000, y: -100000)
        controller.dismissDetailsIfOutside()
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        XCTAssertNil(controller.model.accountPicker)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.model.isExpanded)
    }

    func testAutomaticAccountSwitchOpensShowsAndRestoresAutoHide() throws {
        let oldID = UUID(), newID = UUID()
        let controller = NotchWindowController(
            cursorLocation: { CGPoint(x: -100000, y: -100000) },
            automaticSwitchDuration: 0.05
        )
        controller.model.snapshots = [ProviderSnapshot(
            id: newID.uuidString,
            displayName: "Production",
            accountEmail: "builder@example.test",
            glyph: .claude,
            fidelity: .official,
            status: .ok,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.1)]
        )]
        let event = AutomaticAccountSwitch(provider: .claude, fromID: oldID,
                                           fromName: "Research", toID: newID,
                                           toName: "Production")
        controller.show()
        controller.apply(.autoHide)
        defer { controller.apply(.hidden); controller.stop() }

        XCTAssertFalse(controller.panelVisibleForTesting)
        controller.presentAutomaticSwitch(event)
        XCTAssertEqual(controller.model.automaticSwitch, event)
        XCTAssertEqual(controller.model.selectedIndex, 0)
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertTrue(controller.model.staysOpen)
        XCTAssertTrue(controller.panelVisibleForTesting)

        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        XCTAssertNil(controller.model.automaticSwitch)
        XCTAssertNil(controller.model.selectedIndex)
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.panelVisibleForTesting)
    }

    func testClickDuringAutomaticSwitchKeepsRequestedDetailsOpen() {
        let oldID = UUID(), newID = UUID(), otherID = UUID()
        let controller = NotchWindowController(automaticSwitchDuration: 10)
        controller.model.snapshots = [
            ProviderSnapshot(id: newID.uuidString, displayName: "Claude Work", glyph: .claude,
                             fidelity: .official, status: .ok, windows: []),
            ProviderSnapshot(id: otherID.uuidString, displayName: "Codex Personal", glyph: .openai,
                             fidelity: .official, status: .ok, windows: [])
        ]
        controller.show()
        controller.apply(.alwaysShow)
        defer { controller.apply(.hidden); controller.stop() }
        controller.presentAutomaticSwitch(AutomaticAccountSwitch(
            provider: .claude, fromID: oldID, fromName: "Claude Personal",
            toID: newID, toName: "Claude Work"))

        controller.toggleDetails(index: 1)
        XCTAssertNil(controller.model.automaticSwitch)
        XCTAssertEqual(controller.model.selectedIndex, 1)
        XCTAssertTrue(controller.model.isExpanded)
    }
}
