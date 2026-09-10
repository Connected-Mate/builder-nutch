import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

private func alert(id: String = "reconnect", title: String = "Claude needs signing in again",
                   accountID: UUID? = nil) -> NotchAlert {
    NotchAlert(id: id, title: title, detail: "The saved login expired.",
               raisedAt: Date(timeIntervalSince1970: 1_000_000), accountID: accountID)
}

private func resolution(id: String = "reconnected", title: String = "Claude is signed in again",
                        detail: String = "", accountID: UUID? = nil) -> NotchResolution {
    NotchResolution(id: id, title: title, detail: detail, accountID: accountID)
}

private func snapshot(id: String) -> ProviderSnapshot {
    ProviderSnapshot(
        id: id, displayName: "Provider \(id)", glyph: .claude,
        fidelity: .official, status: .ok,
        windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)],
        headlineID: "session"
    )
}

// MARK: - The green itself

final class ResolvedSkinTests: XCTestCase {
    /// Same construction, same locations, same three lightness steps. Going
    /// from red to green must change the notch's hue and nothing else — a green
    /// that also brightened would read as a second, louder event rather than as
    /// the first one ending.
    func testTheGreenRampMirrorsTheRedOne() {
        let red = NotchAlertSkin.stops
        let green = NotchAlertSkin.resolvedStops
        XCTAssertEqual(red.count, green.count)
        XCTAssertEqual(red.map(\.location), green.map(\.location))
        XCTAssertEqual(green.first?.color, Palette.notch,
                       "The bezel edge must stay black in both states")
        XCTAssertEqual(green.last?.color, Palette.resolved)
    }

    /// The same discipline the red is held to. A resolution nobody can see on a
    /// pale wallpaper is a resolution that did not happen.
    func testTheGreenCarriesOnLightAndDarkAlike() throws {
        let colour = try XCTUnwrap(NSColor(Palette.resolved).usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(colour.redComponent)
            + 0.7152 * channel(colour.greenComponent)
            + 0.0722 * channel(colour.blueComponent)
        XCTAssertGreaterThan(1.05 / (luminance + 0.05), 3, "Lost against a pale wallpaper")
        XCTAssertGreaterThan((luminance + 0.05) / 0.05, 3, "Lost against a dark wallpaper")
    }

    /// One soft swell, not three sharp beats — and it gives light rather than
    /// taking it, or the green borrows the signal that means something failed.
    func testTheResolvedPulseIsGentlerThanTheAlertFlash() {
        XCTAssertLessThan(NotchPulse.resolvedDuration, NotchPulse.duration)
        XCTAssertGreaterThan(NotchPulse.resolvedSwell, 1)
        XCTAssertLessThan(NotchPulse.resolvedSwell, NotchPulse.swell)
        // Rising slower than it falls is what makes it a swell rather than a blink.
        XCTAssertLessThan(NotchPulse.resolvedRise, NotchPulse.resolvedFall)
    }

    /// The lead asked for roughly 450 ms out, and for the removal never to be a
    /// hard cut. It is also the one exit in this app that is longer than its
    /// entrance, because here the fade is the message.
    func testTheColourLeavesMoreSlowlyThanItArrives() {
        XCTAssertEqual(NotchMotion.skinClearDuration, 0.45, accuracy: 0.0001)
        XCTAssertGreaterThan(NotchMotion.skinClearDuration, NotchMotion.skinRaiseDuration)
        // Never a hard cut, in either direction.
        XCTAssertGreaterThan(NotchMotion.skinRaiseDuration, 0.2)
    }

    /// Reduced motion keeps the colour and drops every bit of movement: the
    /// gradient still says what happened, it just says it without moving.
    func testReducedMotionLeavesTheColourAndNothingElse() {
        XCTAssertNil(NotchMotion.respectingReduceMotion(NotchMotion.skinRaise, true))
        XCTAssertNil(NotchMotion.respectingReduceMotion(NotchMotion.skinClear, true))
        XCTAssertNotNil(NotchMotion.respectingReduceMotion(NotchMotion.skinClear, false))
    }
}

// MARK: - Precedence

@MainActor
final class NotchSkinPrecedenceTests: XCTestCase {
    private func model() -> NotchViewModel {
        let model = NotchViewModel()
        model.snapshots = [snapshot(id: "a"), snapshot(id: "b")]
        model.isExpanded = true
        return model
    }

    func testNothingWrongIsBlack() {
        XCTAssertEqual(model().skin, .calm)
    }

    /// Scenario: red, the user reconnects, green, then black.
    func testAProblemFixedGoesRedThenGreenThenBlack() {
        let model = model()
        model.attention = alert()
        XCTAssertEqual(model.skin, .alert)

        model.attention = nil
        model.resolution = resolution()
        XCTAssertEqual(model.skin, .resolved)
        XCTAssertEqual(model.status?.tone, .resolved)
        XCTAssertEqual(model.status?.title, "Claude is signed in again")

        model.resolution = nil
        XCTAssertEqual(model.skin, .calm)
        XCTAssertNil(model.status)
    }

    /// Scenario: the account was removed rather than fixed. Nobody publishes a
    /// resolution, so the notch simply fades back to black and never claims
    /// something was put right.
    func testAProblemThatDisappearsWithoutBeingFixedShowsNoGreen() {
        let model = model()
        model.attention = alert()
        model.attention = nil
        XCTAssertEqual(model.skin, .calm)
        XCTAssertNil(model.resolution)
    }

    /// Scenario: two problems, one fixed. The red stays, wearing the title of
    /// the one still standing, because the notch is not yet safe to ignore.
    func testFixingOneOfTwoProblemsKeepsTheRed() {
        let model = model()
        model.attention = alert(id: "keychainAccess", title: "macOS is blocking a login")
        model.resolution = resolution()
        XCTAssertEqual(model.skin, .alert, "Green shown while something was still broken")
        XCTAssertEqual(model.status?.title, "macOS is blocking a login")
    }

    /// A problem arriving during the green ends it there and then.
    func testANewProblemDuringTheGreenWinsImmediately() {
        let model = model()
        model.resolution = resolution()
        XCTAssertEqual(model.skin, .resolved)

        model.attention = alert()
        XCTAssertEqual(model.skin, .alert)
        XCTAssertNil(model.resolution, "The green outlived the problem that replaced it")
    }

    /// The swell lands on the ring that actually recovered.
    func testOnlyTheRecoveredRingSwells() {
        let model = model()
        let account = UUID()
        model.snapshots = [snapshot(id: account.uuidString), snapshot(id: "other")]
        model.resolution = resolution(accountID: account)
        XCTAssertNotNil(model.resolutionPulse(forSnapshot: account.uuidString))
        XCTAssertNil(model.resolutionPulse(forSnapshot: "other"))
        XCTAssertEqual(model.statusIndex, 0)
    }

    /// The green card has nothing to fix, so it must not tell anybody the notch
    /// is a button to a problem.
    func testOnlyTheRedCardOffersTheClickHint() {
        let withHint = NotchLayout.statusCardHeight(detail: "Something.", showsHint: true)
        let without = NotchLayout.statusCardHeight(detail: "Something.", showsHint: false)
        XCTAssertGreaterThan(withHint, without)
        // A handoff with nothing to add is a title and no body at all.
        XCTAssertLessThan(NotchLayout.statusCardHeight(detail: "", showsHint: false), without)
    }
}

// MARK: - What is painted

@MainActor
final class ResolvedRenderTests: XCTestCase {
    private func model(edge: NotchEdge, attention: NotchAlert?,
                       resolution: NotchResolution?) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        model.snapshots = [snapshot(id: "a"), snapshot(id: "b")]
        model.resolution = resolution
        model.attention = attention
        return model
    }

    private func render(_ model: NotchViewModel) -> NSBitmapImageRep? {
        let size = model.panelSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: model).frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Green pixels: green clearly ahead of both neighbours.
    private func greenFraction(_ rep: NSBitmapImageRep) -> Double {
        var green = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.5 else { continue }
                total += 1
                let rest = max(colour.redComponent, colour.blueComponent)
                if colour.greenComponent - rest > 0.12 { green += 1 }
            }
        }
        return total == 0 ? 0 : Double(green) / Double(total)
    }

    func testTheNotchTurnsGreenOnlyOnAResolutionOnEveryEdge() throws {
        for edge in NotchEdge.allCases {
            let calm = try XCTUnwrap(render(model(edge: edge, attention: nil, resolution: nil)))
            let quiet = greenFraction(calm)

            let resolved = try XCTUnwrap(
                render(model(edge: edge, attention: nil, resolution: resolution())))
            XCTAssertGreaterThan(greenFraction(resolved), quiet + 0.1,
                                 "Nothing went green on \(edge)")

            // Red wins: a resolution that arrives while something is still
            // broken paints no green at all.
            let contested = try XCTUnwrap(
                render(model(edge: edge, attention: alert(), resolution: resolution())))
            XCTAssertLessThan(greenFraction(contested), quiet + 0.05,
                              "Green leaked through the red on \(edge)")
        }
    }

    /// The whole reason the ramp starts at `Palette.notch`: the shape has to
    /// keep reading as part of the bezel in every state.
    func testTheEdgeStaysBlackWhileGreen() throws {
        let rep = try XCTUnwrap(
            render(model(edge: .right, attention: nil, resolution: resolution())))
        let y = rep.pixelsHigh / 2
        var found: NSColor?
        for x in stride(from: rep.pixelsWide - 1, through: rep.pixelsWide * 3 / 4, by: -1) {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  colour.alphaComponent > 0.5 else { continue }
            found = colour
            break
        }
        let colour = try XCTUnwrap(found, "Nothing drawn along the bezel at all")
        XCTAssertLessThan(colour.greenComponent, 0.2, "The bezel edge is no longer black")
        XCTAssertLessThan(colour.redComponent, 0.2)
    }

    /// The live-update complaint from the installed build: the red did not go
    /// away when the situation changed. Clearing the model must clear the paint.
    func testClearingTheProblemClearsThePaint() throws {
        let red = try XCTUnwrap(render(model(edge: .right, attention: alert(), resolution: nil)))
        let cleared = try XCTUnwrap(render(model(edge: .right, attention: nil, resolution: nil)))

        func redFraction(_ rep: NSBitmapImageRep) -> Double {
            var hot = 0, total = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          colour.alphaComponent > 0.5 else { continue }
                    total += 1
                    let rest = max(colour.greenComponent, colour.blueComponent)
                    if colour.redComponent - rest > 0.12 { hot += 1 }
                }
            }
            return total == 0 ? 0 : Double(hot) / Double(total)
        }
        XCTAssertGreaterThan(redFraction(red), redFraction(cleared) + 0.1)
    }
}

// MARK: - The hold

@MainActor
final class ResolutionHoldTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func controller(hold: TimeInterval) -> NotchWindowController {
        let controller = NotchWindowController(cursorLocation: { .zero }, resolutionHold: hold)
        controller.model.snapshots = [snapshot(id: "a")]
        return controller
    }

    func testTheGreenHoldsThenLetsGoByItself() {
        let controller = controller(hold: 0.25)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        controller.presentResolution(resolution())
        XCTAssertEqual(controller.model.skin, .resolved)
        pump(0.1)
        XCTAssertEqual(controller.model.skin, .resolved, "Let go too early")
        pump(0.3)
        XCTAssertEqual(controller.model.skin, .calm, "Never let go")
    }

    /// Scenario: fixing one of two problems. The account layer may still
    /// publish a resolution, and the notch must decline to show it.
    func testAResolutionArrivingWhileSomethingIsStillBrokenIsDeclined() {
        let controller = controller(hold: 0.25)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        controller.model.attention = alert()
        controller.presentResolution(resolution())
        XCTAssertNil(controller.model.resolution)
        XCTAssertEqual(controller.model.skin, .alert)
    }

    /// The same good news republished on every refresh must not restart the
    /// hold, or the green would never end while the manager kept the value set.
    func testTheSameResolutionTwiceDoesNotExtendTheHold() {
        let controller = controller(hold: 0.3)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        controller.presentResolution(resolution())
        pump(0.2)
        controller.presentResolution(resolution())
        pump(0.2)
        XCTAssertEqual(controller.model.skin, .calm, "A repeat restarted the hold")
    }

    /// Scenario: automatic handoff with no prior red. Short green, carrying the
    /// sentence that says which limit actually ran out.
    func testAHandoffWithNoPriorProblemStillShowsItsReason() {
        let controller = controller(hold: 0.25)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        controller.presentResolution(resolution(
            id: "switched", title: "Switched to Claude 5",
            detail: "Claude 3 had 12% left on its Weekly limit."))
        XCTAssertEqual(controller.model.skin, .resolved)
        XCTAssertEqual(controller.model.status?.detail,
                       "Claude 3 had 12% left on its Weekly limit.")
    }

    /// Auto-hide has to peek for the green too, or the recovery is painted onto
    /// a panel nobody can see.
    func testAutoHideShowsTheHandleForTheGreenAsWell() throws {
        let controller = controller(hold: 0.4)
        controller.apply(.autoHide)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        XCTAssertFalse(controller.panelVisibleForTesting)
        controller.presentResolution(resolution())
        XCTAssertTrue(controller.panelVisibleForTesting)
        pump(0.5)
        XCTAssertFalse(controller.panelVisibleForTesting,
                       "The handle stayed out after the green ended")
    }

    /// Off means off, in green as well as in red.
    func testOffStaysOffThroughAResolution() {
        let controller = controller(hold: 0.25)
        controller.show()
        controller.apply(.hidden)
        defer { controller.stop() }

        controller.presentResolution(resolution())
        XCTAssertNil(controller.model.resolution)
        XCTAssertFalse(controller.panelVisibleForTesting)
    }
}
