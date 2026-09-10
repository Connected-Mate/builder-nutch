import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// Collects what would have been said, so nothing here touches the real
/// notification centre — see `UserNotifying` for why that matters.
private final class RecordingNotifier: UserNotifying {
    var posted: [UserNotice] = []
    func post(_ notice: UserNotice) { posted.append(notice) }
}

private func makeAlert(
    id: String = "reconnect",
    title: String = "Claude needs signing in again",
    detail: String = "The saved login expired. Open Builder Nutch to reconnect it.",
    raisedAt: Date = Date(timeIntervalSince1970: 1_000_000),
    accountID: UUID? = nil
) -> NotchAlert {
    NotchAlert(id: id, title: title, detail: detail,
               raisedAt: raisedAt, accountID: accountID)
}

private func makeSnapshot(id: String, used: Double?, resetsAt: Date? = nil,
                          name: String? = nil, derivedReset: Bool? = nil) -> ProviderSnapshot {
    ProviderSnapshot(
        id: id, displayName: name ?? "Provider \(id)", glyph: .claude,
        fidelity: .official, status: .ok,
        windows: [LimitWindow(id: "session", label: "Session",
                              usedFraction: used, resetsAt: resetsAt,
                              derivedReset: derivedReset)],
        headlineID: "session"
    )
}

// MARK: - The skin

final class NotchAlertSkinTests: XCTestCase {
    func testBlackStaysAtTheBezelAndTheRedIsSpentOnTheInnerFace() {
        let stops = NotchAlertSkin.stops
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.first?.color, Palette.notch,
                       "The edge the notch is welded to must stay the exact existing black")
        XCTAssertEqual(stops.last?.color, Palette.alert)
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted())
        // Weighted late on purpose: the rings sit in the first two thirds and
        // their white glyphs have to stay legible.
        XCTAssertGreaterThanOrEqual(stops[1].location, 0.5)
    }

    /// The gradient must run from the bezel inward on every placement, which is
    /// the same direction `NotchEdge` already names. Two hand-written tables
    /// that must agree is one chance to disagree.
    func testTheGradientRunsFromTheBezelInwardOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let points = NotchAlertSkin.unitPoints(for: edge)
            // UnitPoint and `outward` share a coordinate sense: x grows right,
            // y grows down.
            XCTAssertEqual(points.start.x - points.end.x, edge.outward.x,
                           accuracy: 0.0001, "Wrong axis on \(edge)")
            XCTAssertEqual(points.start.y - points.end.y, edge.outward.y,
                           accuracy: 0.0001, "Wrong axis on \(edge)")
        }
    }

    /// The card's tail carries the red at the end that touches the notch, so
    /// the join is a continuation rather than a black object stuck to a red
    /// edge. Each direction's hot end must be the end the tip is on.
    func testTheAlertTailIsHotWhereItMeetsTheNotch() {
        for edge in NotchEdge.allCases {
            let direction = edge.tooltipDirection
            let tail = NotchAlertSkin.tailUnitPoints(for: direction)
            // Both are the same axis and the same sense — "toward the screen
            // edge". The tail's point aims back at the notch, and the notch's
            // gradient starts at the bezel, so the two vectors coincide even
            // though the colours at that end are opposite: black on the notch,
            // red on the tail, which is what makes the join continuous.
            let skin = NotchAlertSkin.unitPoints(for: edge)
            XCTAssertEqual(tail.tip, skin.start,
                           "Tail and notch disagree about which end is hot on \(edge)")
            XCTAssertEqual(tail.base, skin.end)
        }
    }

    /// The one accent has to survive both wallpapers, so it is checked rather
    /// than trusted.
    func testTheAlertRedCarriesOnLightAndDarkAlike() throws {
        let colour = try XCTUnwrap(NSColor(Palette.alert).usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(colour.redComponent)
            + 0.7152 * channel(colour.greenComponent)
            + 0.0722 * channel(colour.blueComponent)
        XCTAssertGreaterThan((1.05) / (luminance + 0.05), 3, "Lost against a pale wallpaper")
        XCTAssertGreaterThan((luminance + 0.05) / 0.05, 3, "Lost against a dark wallpaper")
    }
}

// MARK: - What is actually painted

@MainActor
final class NotchAlertRenderTests: XCTestCase {
    private func model(edge: NotchEdge, alert: NotchAlert?,
                       hovering: Bool = false) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        model.snapshots = (0..<2).map { makeSnapshot(id: "p\($0)", used: 0.4) }
        model.attention = alert
        model.isHoveringNotch = hovering
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

    /// Fraction of sampled pixels that are recognisably red rather than grey.
    private func redFraction(_ rep: NSBitmapImageRep) -> Double {
        var red = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.5 else { continue }
                total += 1
                let rest = max(colour.greenComponent, colour.blueComponent)
                if colour.redComponent - rest > 0.12 { red += 1 }
            }
        }
        return total == 0 ? 0 : Double(red) / Double(total)
    }

    func testTheNotchTurnsRedOnlyWhenSomethingNeedsDoingOnEveryEdge() throws {
        for edge in NotchEdge.allCases {
            // Never zero: the provider marks are the real service logos and
            // several of them are warm, which is why this is a comparison
            // rather than an absolute floor.
            let calm = try XCTUnwrap(render(model(edge: edge, alert: nil)))
            let quiet = redFraction(calm)
            XCTAssertLessThan(quiet, 0.05,
                              "The ordinary notch has gone colourful on \(edge)")

            let raised = try XCTUnwrap(render(model(edge: edge, alert: makeAlert())))
            XCTAssertGreaterThan(redFraction(raised), quiet + 0.1,
                                 "Nothing went red on \(edge)")
        }
    }

    /// The whole point of the black at the bezel: the shape has to keep reading
    /// as part of the screen's edge rather than as a badge stuck onto it.
    func testTheEdgeItselfStaysBlack() throws {
        let rep = try XCTUnwrap(render(model(edge: .right, alert: makeAlert())))
        let y = rep.pixelsHigh / 2
        // Walked in from the outside rather than sampled at a fixed column:
        // the panel's width is whatever the renderer rounded to, and the last
        // column or two can be empty without the notch having moved.
        var found: NSColor?
        for x in stride(from: rep.pixelsWide - 1, through: rep.pixelsWide * 3 / 4, by: -1) {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  colour.alphaComponent > 0.5 else { continue }
            found = colour
            break
        }
        let colour = try XCTUnwrap(found, "Nothing drawn along the bezel at all")
        XCTAssertLessThan(colour.redComponent, 0.2, "The bezel edge is no longer black")
        XCTAssertLessThan(colour.greenComponent, 0.2)
        XCTAssertLessThan(colour.blueComponent, 0.2)
    }

    /// Fraction of sampled pixels painted at all — the same measure the other
    /// notch render tests use.
    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// The card is a hover affordance. Under Always show the notch is never
    /// folded, so without the hover test it would park itself on the desktop
    /// for the whole hour.
    func testTheAlertCardIsOnlyThereWhileThePointerIs() throws {
        let unattended = model(edge: .right, alert: makeAlert(), hovering: false)
        XCTAssertFalse(unattended.showsStatusCard)
        let quiet = try XCTUnwrap(render(unattended))

        let hovered = model(edge: .right, alert: makeAlert(), hovering: true)
        XCTAssertTrue(hovered.showsStatusCard)
        let loud = try XCTUnwrap(render(hovered))

        XCTAssertGreaterThan(inkedFraction(loud), inkedFraction(quiet) * 1.2,
                             "Hovering an alerted notch drew no card")
    }

    /// Opening a provider's own usage stands the alert card down, so the two
    /// never contest the same space.
    func testOpeningUsageDetailsStandsTheAlertCardDown() {
        let model = model(edge: .right, alert: makeAlert(), hovering: true)
        XCTAssertTrue(model.showsStatusCard)
        model.selectedIndex = 0
        XCTAssertFalse(model.showsStatusCard)
    }
}

// MARK: - The flash

final class NotchPulseTests: XCTestCase {
    func testThreeBeatsInAboutAndAHalfSecondAndNoBounce() {
        XCTAssertEqual(NotchPulse.count, 3)
        XCTAssertEqual(NotchPulse.duration, 1.2, accuracy: 0.0001)
        // Down fast, back slowly: the asymmetry is what makes it a pulse.
        XCTAssertLessThan(NotchPulse.dip, NotchPulse.rise)
        // Dimmed, never gone — a glyph that vanishes reads as a fault.
        XCTAssertGreaterThan(NotchPulse.dimmed, 0.2)
        XCTAssertLessThan(NotchPulse.dimmed, 1)
        // Small: the ring around it does not move.
        XCTAssertLessThan(NotchPulse.swell, 1.2)
    }
}

@MainActor
final class NotchAttentionModelTests: XCTestCase {
    private func model() -> NotchViewModel {
        let model = NotchViewModel()
        model.snapshots = (0..<2).map { makeSnapshot(id: "p\($0)", used: 0.4) }
        return model
    }

    func testTheFlashWaitsForSomebodyToBeLookingAndPlaysOncePerProblem() {
        let model = model()
        let alert = makeAlert()
        model.isExpanded = false
        model.attention = alert
        XCTAssertNil(model.attentionFlash, "Flashed at a folded notch")

        model.isExpanded = true
        model.armAttentionFlash()
        XCTAssertEqual(model.attentionFlash, alert.id)

        // Folding and reopening is not a new problem, so the trigger does not
        // change and nothing replays.
        model.isExpanded = false
        model.isExpanded = true
        model.armAttentionFlash()
        XCTAssertEqual(model.attentionFlash, alert.id)

        // A different problem is a new event.
        let other = makeAlert(id: "keychainAccess")
        model.attention = other
        XCTAssertEqual(model.attentionFlash, other.id)

        // Fixed and back again is also a new event.
        model.attention = nil
        XCTAssertNil(model.attentionFlash)
        model.attention = other
        XCTAssertEqual(model.attentionFlash, other.id)
    }

    func testOnlyTheRingBeingComplainedAboutFlashes() {
        let model = model()
        let account = UUID()
        model.snapshots = [makeSnapshot(id: account.uuidString, used: 0.4),
                           makeSnapshot(id: "other", used: 0.4)]
        model.isExpanded = true
        model.attention = makeAlert(accountID: account)
        XCTAssertEqual(model.attentionFlash(forSnapshot: account.uuidString), model.attentionFlash)
        XCTAssertNil(model.attentionFlash(forSnapshot: "other"))
        XCTAssertEqual(model.statusIndex, 0)

        // A problem belonging to no single account belongs to all of them.
        model.attention = makeAlert(id: "switchPaused", accountID: nil)
        XCTAssertNotNil(model.attentionFlash(forSnapshot: account.uuidString))
        XCTAssertNotNil(model.attentionFlash(forSnapshot: "other"))
        XCTAssertEqual(model.statusIndex, 0)
    }
}

// MARK: - Escalation

@MainActor
final class AttentionEscalatorTests: XCTestCase {
    private let raised = Date(timeIntervalSince1970: 1_000_000)

    private func escalator(_ notifier: RecordingNotifier) -> AttentionEscalator {
        AttentionEscalator(notifier: notifier, delay: 3600, clock: { self.raised })
    }

    func testNothingIsSaidBeforeTheHourAndOnlyOnceAfterIt() {
        let notifier = RecordingNotifier()
        let escalator = escalator(notifier)
        defer { escalator.stop() }
        let alert = makeAlert(raisedAt: raised)
        escalator.update(alert)

        XCTAssertNil(escalator.evaluate(now: raised.addingTimeInterval(3599)))
        XCTAssertTrue(notifier.posted.isEmpty)

        let notice = escalator.evaluate(now: raised.addingTimeInterval(3600))
        XCTAssertEqual(notice?.title, alert.title)
        XCTAssertEqual(notice?.body, alert.detail)
        XCTAssertEqual(notifier.posted.count, 1)

        // Still broken an hour later is not a second thing to say.
        XCTAssertNil(escalator.evaluate(now: raised.addingTimeInterval(7200)))
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testOpeningTheAccountsWindowCountsAsHavingSeenIt() {
        let notifier = RecordingNotifier()
        let escalator = escalator(notifier)
        defer { escalator.stop() }
        escalator.update(makeAlert(raisedAt: raised))
        escalator.accountsWindowOpened(at: raised.addingTimeInterval(60))

        XCTAssertNil(escalator.evaluate(now: raised.addingTimeInterval(3600)))
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testLookingAtItBeforeItHappenedIsNotHavingSeenIt() {
        let notifier = RecordingNotifier()
        let escalator = escalator(notifier)
        defer { escalator.stop() }
        escalator.accountsWindowOpened(at: raised.addingTimeInterval(-60))
        escalator.update(makeAlert(raisedAt: raised))

        XCTAssertNotNil(escalator.evaluate(now: raised.addingTimeInterval(3600)))
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testADifferentProblemGetsItsOwnHourAndItsOwnNotification() {
        let notifier = RecordingNotifier()
        let escalator = escalator(notifier)
        defer { escalator.stop() }
        escalator.update(makeAlert(id: "reconnect", raisedAt: raised))
        escalator.evaluate(now: raised.addingTimeInterval(3600))
        XCTAssertEqual(notifier.posted.count, 1)

        let later = raised.addingTimeInterval(10_000)
        escalator.update(makeAlert(id: "queueEmpty", raisedAt: later))
        XCTAssertNil(escalator.evaluate(now: later.addingTimeInterval(3599)))
        XCTAssertNotNil(escalator.evaluate(now: later.addingTimeInterval(3600)))
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertNotEqual(notifier.posted[0].id, notifier.posted[1].id)
    }

    func testAProblemThatOutlivedARelaunchIsEscalatedStraightAway() {
        let notifier = RecordingNotifier()
        let escalator = escalator(notifier)
        defer { escalator.stop() }
        // `raisedAt` is when the problem started, not when we heard of it, so
        // an app restarted two hours in is already overdue.
        escalator.update(makeAlert(raisedAt: raised.addingTimeInterval(-7200)))
        XCTAssertEqual(notifier.posted.count, 1)
    }
}

// MARK: - Usage thresholds

@MainActor
final class UsageThresholdNotifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testEachThresholdIsSaidOnceAndOnlyOnce() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        let resets = now.addingTimeInterval(3000)

        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.40, resetsAt: resets)], now: now)
        XCTAssertTrue(notifier.posted.isEmpty)

        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.50, resetsAt: resets)], now: now)
        XCTAssertEqual(notifier.posted.count, 1)

        // 84.6% is not 85% yet.
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.846, resetsAt: resets)], now: now)
        XCTAssertEqual(notifier.posted.count, 2, "75 should have been crossed, 85 should not")
        XCTAssertTrue(notifier.posted[1].title.contains("75"))

        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.85, resetsAt: resets)], now: now)
        XCTAssertEqual(notifier.posted.count, 3)
        XCTAssertTrue(notifier.posted[2].title.contains("85"))

        // Sitting at 90% is not news.
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.90, resetsAt: resets)], now: now)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.99, resetsAt: resets)], now: now)
        XCTAssertEqual(notifier.posted.count, 3)
    }

    func testCrossingSeveralAtOnceSaysTheHighestRatherThanStackingThree() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.05)], now: now)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.92)], now: now)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(notifier.posted[0].title.contains("85"))
    }

    func testTheSlateIsWipedWhenTheWindowRolls() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        let first = now.addingTimeInterval(600)
        // Establish the window first. A window's first sighting is never an
        // event — see `testAlreadyHighAtLaunchIsNotNews`.
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.10, resetsAt: first)], now: now)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.90, resetsAt: first)], now: now)
        XCTAssertEqual(notifier.posted.count, 1)

        let second = now.addingTimeInterval(18_000)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.02, resetsAt: second)], now: now)
        XCTAssertEqual(notifier.posted.count, 1, "An empty new window is not news")

        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.55, resetsAt: second)], now: now)
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertTrue(notifier.posted[1].title.contains("50"))
    }

    func testEachAccountKeepsItsOwnRecord() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.evaluate(snapshots: [
            makeSnapshot(id: "a", used: 0.10, name: "Claude"),
            makeSnapshot(id: "b", used: 0.10, name: "Codex")
        ], now: now)
        thresholds.evaluate(snapshots: [
            makeSnapshot(id: "a", used: 0.55, name: "Claude"),
            makeSnapshot(id: "b", used: 0.10, name: "Codex")
        ], now: now)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(notifier.posted[0].title.contains("Claude"))

        thresholds.evaluate(snapshots: [
            makeSnapshot(id: "a", used: 0.55, name: "Claude"),
            makeSnapshot(id: "b", used: 0.60, name: "Codex")
        ], now: now)
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertTrue(notifier.posted[1].title.contains("Codex"))
    }

    /// Switched off, the points that go by are history rather than news:
    /// turning the setting back on must not fire for them.
    func testSwitchingItOffIsSilentAndSwitchingItBackOnIsNotABacklog() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.isEnabled = false
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.80)], now: now)
        XCTAssertTrue(notifier.posted.isEmpty)

        thresholds.isEnabled = true
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.80)], now: now)
        XCTAssertTrue(notifier.posted.isEmpty)

        // The next genuinely new point still arrives.
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.87)], now: now)
        XCTAssertEqual(notifier.posted.count, 1)
    }

    /// The record lives in memory only, so every launch starts blank. Opening
    /// the app with accounts already past half must not fire for all of them on
    /// the spot — and then do it again at the next launch, and the next. The
    /// promise is "tell me when an account crosses 50%", not "tell me it is
    /// above 50%".
    func testAlreadyHighAtLaunchIsNotNews() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.evaluate(snapshots: [
            makeSnapshot(id: "a", used: 0.62, name: "Claude"),
            makeSnapshot(id: "b", used: 0.91, name: "Codex")
        ], now: now)
        XCTAssertTrue(notifier.posted.isEmpty,
                      "Launching the app announced usage nobody had just crossed")

        // A restart is another blank record, and just as quiet.
        let afterRelaunch = UsageThresholdNotifier(notifier: notifier)
        afterRelaunch.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.62)], now: now)
        XCTAssertTrue(notifier.posted.isEmpty)

        // But a point crossed while the app is watching still arrives.
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: 0.77)], now: now)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(notifier.posted[0].title.contains("75"))
    }

    /// One model's weekly allowance running out is not the subscription running
    /// out. The title has to say which, or it claims the account is nearly
    /// spent when everything except that one model still works.
    func testAModelSpecificLimitNamesTheModelRatherThanTheAccount() {
        let account = makeSnapshot(id: "a", used: 0.86, name: "Claude")
        let whole = UsageThresholdNotifier.notice(
            snapshot: account,
            window: LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: 0.86),
            threshold: 85, now: now)
        let oneModel = UsageThresholdNotifier.notice(
            snapshot: account,
            window: LimitWindow(id: "weekly", label: "Fable weekly limit",
                                usedFraction: 0.86, modelName: "Fable"),
            threshold: 85, now: now)

        XCTAssertFalse(whole.title.contains("Fable"))
        XCTAssertTrue(oneModel.title.contains("Fable"),
                      "A model's limit was reported as the whole account's")
        XCTAssertTrue(oneModel.title.contains("Claude"))
        XCTAssertTrue(oneModel.title.contains("85"))
    }

    func testAWindowWithNoDenominatorIsNeverGuessedAt() {
        let notifier = RecordingNotifier()
        let thresholds = UsageThresholdNotifier(notifier: notifier)
        thresholds.evaluate(snapshots: [makeSnapshot(id: "a", used: nil)], now: now)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testTheCopySaysWhoWhatAndWhen() {
        let resets = now.addingTimeInterval(51 * 60)
        let notice = UsageThresholdNotifier.notice(
            snapshot: makeSnapshot(id: "a", used: 0.76, resetsAt: resets, name: "Claude"),
            window: LimitWindow(id: "session", label: "Session",
                                usedFraction: 0.76, resetsAt: resets),
            threshold: 75, now: now
        )
        XCTAssertTrue(notice.title.contains("Claude"))
        XCTAssertTrue(notice.title.contains("75"))
        XCTAssertTrue(notice.body.contains("Session"))
        XCTAssertTrue(notice.body.contains("25"), "Should say what is left, not only what is spent")
        XCTAssertTrue(notice.body.contains("Resets"))
    }

    /// A reset worked out from a written hint rather than sent by the vendor
    /// must not be quoted to the minute. Kimi reports "resets in 2d 6h 36m" and
    /// nothing else, and a notification is read once and acted on.
    func testADerivedResetIsMarkedApproximateInTheNotification() {
        let resets = now.addingTimeInterval(51 * 60)
        let sent = UsageThresholdNotifier.notice(
            snapshot: makeSnapshot(id: "a", used: 0.76, resetsAt: resets),
            window: LimitWindow(id: "session", label: "Session",
                                usedFraction: 0.76, resetsAt: resets),
            threshold: 75, now: now
        )
        let inferred = UsageThresholdNotifier.notice(
            snapshot: makeSnapshot(id: "a", used: 0.76, resetsAt: resets, derivedReset: true),
            window: LimitWindow(id: "session", label: "Session",
                                usedFraction: 0.76, resetsAt: resets, derivedReset: true),
            threshold: 75, now: now
        )
        XCTAssertNotEqual(sent.body, inferred.body,
                          "An inferred reset was quoted as precisely as a sent one")
        XCTAssertTrue(inferred.body.contains(
            ResetCopy.text(for: resets, now: now, derived: true)))
    }
}

// MARK: - The notch as a button

@MainActor
final class NotchAlertInteractionTests: XCTestCase {
    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testAutoHideStillShowsTheHandleWhileSomethingNeedsDoing() throws {
        let screen = try XCTUnwrap(NotchGeometry.preferredScreen(from: NSScreen.screens))
        var pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = [makeSnapshot(id: "a", used: 0.4)]
        controller.apply(.autoHide)
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        XCTAssertFalse(controller.panelVisibleForTesting)

        controller.model.attention = makeAlert()
        pump()
        XCTAssertTrue(controller.panelVisibleForTesting,
                      "Auto-hide swallowed the one thing the user has to see")

        controller.model.attention = nil
        pump()
        XCTAssertFalse(controller.panelVisibleForTesting,
                       "The handle stayed out after the problem went away")
    }

    /// Off means off. An alert does not overrule a setting that asked for
    /// nothing on screen — the escalation is the part that was not switched off.
    func testOffStaysOffEvenWithAProblemStanding() throws {
        var pointer = CGPoint.zero
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = [makeSnapshot(id: "a", used: 0.4)]
        controller.show()
        controller.apply(.hidden)
        defer { controller.stop() }
        controller.model.attention = makeAlert()
        pump()
        XCTAssertFalse(controller.panelVisibleForTesting)
    }

    func testClickingTheAlertedNotchGoesToTheProblem() throws {
        var pointer = CGPoint.zero
        let controller = NotchWindowController(cursorLocation: { pointer })
        controller.model.snapshots = (0..<2).map { makeSnapshot(id: "p\($0)", used: 0.4) }
        var opened = 0
        controller.onOpenSettings = { opened += 1 }
        controller.show()
        defer { controller.apply(.hidden); controller.stop() }

        controller.apply(.autoHide)
        controller.model.attention = makeAlert()
        pump()
        // Folded: the red handle is a button to the problem, not a lid to lift.
        controller.handleClick()
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(controller.model.isExpanded)

        // Open: a ring click also goes to the problem rather than to usage.
        controller.apply(.alwaysShow)
        controller.model.attention = makeAlert()
        pump()
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let model = controller.model
        let local = NotchPlacement(edge: model.edge, panelSize: frame.size).point(
            along: model.slack + model.ringCenter(index: 0),
            across: model.contentInset + NotchLayout.bodyDepth(for: model.edge) / 2)
        pointer = CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)
        controller.handleClick()
        XCTAssertEqual(opened, 2)
        XCTAssertNil(controller.model.selectedIndex,
                     "The alerted notch opened usage details instead of the problem")

        // With nothing wrong, the same click is the ordinary one again.
        controller.model.attention = nil
        pump()
        controller.handleClick()
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(controller.model.selectedIndex, 0)
    }
}
