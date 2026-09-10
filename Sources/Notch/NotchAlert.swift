import SwiftUI

/// Something that needs doing, in the shape the notch needs it.
///
/// A translation of the account layer's `AccountAttention` rather than the
/// thing itself. The notch is drawn entirely from `NotchViewModel`, and a view
/// model that reached into the account layer for one field would drag every
/// render test in with it.
struct NotchAlert: Equatable, Identifiable {
    /// Stable for as long as the same problem stands, so the flash plays once
    /// and the escalation fires once.
    let id: String
    let title: String
    let detail: String
    /// When the problem was first noticed — not when the notch was told about
    /// it. The hour before escalating is counted from here, so restarting the
    /// app does not quietly restart the clock.
    let raisedAt: Date
    /// The account concerned, when there is one. Nil means the app as a whole,
    /// and then every ring carries the flash rather than an arbitrary one.
    let accountID: UUID?

    init(id: String, title: String, detail: String,
         raisedAt: Date, accountID: UUID? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.raisedAt = raisedAt
        self.accountID = accountID
    }

    /// The same account in the notch's own id space, which is the account's
    /// UUID written out — see `AppDelegate.updateNotch()`.
    var snapshotID: String? { accountID?.uuidString }

    /// Whether this cell is the one being complained about.
    func concerns(snapshotID id: String) -> Bool {
        snapshotID.map { $0 == id } ?? true
    }
}

/// A problem that has just been fixed.
///
/// Deliberately a separate type from `NotchAlert` rather than a flag on it. An
/// alert is a state that lasts until somebody acts; this is an event that is
/// over the moment it is shown, and giving them one type would mean every place
/// that asks "is something wrong" having to also ask "or was it".
struct NotchResolution: Equatable, Identifiable {
    /// Stable per event, so the same recovery is never shown twice.
    let id: String
    let title: String
    /// May be empty — an automatic handoff sometimes has nothing to add beyond
    /// the fact that it happened.
    let detail: String
    /// The account that recovered, when there is one.
    let accountID: UUID?

    init(id: String, title: String, detail: String = "", accountID: UUID? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.accountID = accountID
    }

    var snapshotID: String? { accountID?.uuidString }

    func concerns(snapshotID id: String) -> Bool {
        snapshotID.map { $0 == id } ?? true
    }
}

/// What the notch is wearing.
///
/// One value rather than two booleans, because the precedence between them is a
/// rule the product has — red wins — and a rule expressed as two independent
/// flags is a rule that eventually gets read in the wrong order somewhere.
enum NotchSkin: Equatable {
    case calm
    case alert
    case resolved
}

/// What the hover card says, in whichever state the notch is in.
struct NotchStatus: Equatable {
    let title: String
    let detail: String
    let tone: NotchSkin
    /// The account concerned, in the notch's own id space.
    let snapshotID: String?
}

/// The notch's alert skin: black where it touches the bezel, hot at the inner
/// lip.
///
/// The shape is welded to a screen edge, and the whole point of it is that it
/// reads as part of the bezel. A pill turned solid red stops being bezel and
/// becomes a floating badge, which is the one thing this shape has always
/// avoided. So the black is kept exactly where the black is load-bearing — at
/// the edge — and the colour is spent on the face you actually see, the way
/// metal glows at the point it is about to give.
///
/// The stops are weighted rather than even. Rings sit between 0.19 and 0.82 of
/// the depth with white glyphs inside them, so the first half of the run stays
/// near-black and everything happens in the last third. Compressed onto the
/// resting handle — nine points deep rather than seventy — the same stops leave
/// a red line along the inner edge, which is exactly what should show when the
/// notch is otherwise hiding.
enum NotchAlertSkin {
    /// Derived in OKLCH so the three reds are perceptually even steps rather
    /// than evenly spaced sRGB numbers, and checked to be in gamut.
    static let stops: [Gradient.Stop] = [
        Gradient.Stop(color: Palette.notch,      location: 0.00),
        Gradient.Stop(color: Palette.alertEmber, location: 0.52),
        Gradient.Stop(color: Palette.alertBlaze, location: 0.84),
        Gradient.Stop(color: Palette.alert,      location: 1.00)
    ]

    /// The answering ramp, at the same locations and the same three lightness
    /// steps. Identical construction is the point: the notch changes hue when a
    /// problem is fixed, and changes nothing else.
    static let resolvedStops: [Gradient.Stop] = [
        Gradient.Stop(color: Palette.notch,         location: 0.00),
        Gradient.Stop(color: Palette.resolvedMoss,  location: 0.52),
        Gradient.Stop(color: Palette.resolvedGrove, location: 0.84),
        Gradient.Stop(color: Palette.resolved,      location: 1.00)
    ]

    static func stops(for skin: NotchSkin) -> [Gradient.Stop] {
        skin == .resolved ? resolvedStops : stops
    }

    /// Bezel first, inside last — for whichever edge the notch is welded to.
    ///
    /// Read off `NotchEdge.outward`, which already names the direction of the
    /// bezel, rather than restated per case: the two must agree, and a second
    /// hand-written table is a second thing to get wrong when an edge is added.
    static func unitPoints(for edge: NotchEdge) -> (start: UnitPoint, end: UnitPoint) {
        switch edge {
        case .right:  return (.trailing, .leading)
        case .left:   return (.leading, .trailing)
        case .top:    return (.top, .bottom)
        case .bottom: return (.bottom, .top)
        }
    }

    static func gradient(for edge: NotchEdge, skin: NotchSkin = .alert) -> LinearGradient {
        let points = unitPoints(for: edge)
        return LinearGradient(stops: stops(for: skin),
                              startPoint: points.start, endPoint: points.end)
    }

    /// The tail that joins the alert card to the notch: hot at the tip, where
    /// it meets the shape's inner lip, and back to the card's own black by the
    /// time it reaches the card.
    ///
    /// Without it the red stops dead at the notch and the card hangs off a red
    /// edge as an unrelated black object — the same seam the notch's flares
    /// exist to remove, reintroduced two inches away.
    /// Which end of the tail is the point, and which is the base. Named
    /// separately from the gradient so it can be checked without unpicking a
    /// `LinearGradient`.
    static func tailUnitPoints(
        for direction: NotchEdge.TooltipDirection
    ) -> (tip: UnitPoint, base: UnitPoint) {
        switch direction {
        case .leading:  return (.trailing, .leading)
        case .trailing: return (.leading, .trailing)
        case .down:     return (.top, .bottom)
        case .up:       return (.bottom, .top)
        }
    }

    static func tailGradient(for direction: NotchEdge.TooltipDirection) -> LinearGradient {
        let (tip, base) = tailUnitPoints(for: direction)
        return tailGradient(for: direction, skin: .alert)
    }

    static func tailGradient(for direction: NotchEdge.TooltipDirection,
                             skin: NotchSkin) -> LinearGradient {
        let (tip, base) = tailUnitPoints(for: direction)
        let hot = skin == .resolved ? Palette.resolved : Palette.alert
        let warm = skin == .resolved ? Palette.resolvedMoss : Palette.alertEmber
        return LinearGradient(
            stops: [
                Gradient.Stop(color: hot, location: 0),
                Gradient.Stop(color: warm, location: 0.55),
                Gradient.Stop(color: Palette.card, location: 1)
            ],
            startPoint: tip, endPoint: base
        )
    }
}

/// What the glyph does when a new problem is raised.
///
/// Three beats and then it stops. Deliberately finite: this file's neighbours
/// document at length what `repeatForever` costs — it does not stop when you
/// set the value back, so anything driven that way has to be cancelled by
/// hand and eventually is not. A counted run has nothing to cancel, and the
/// steady red gradient is what carries the state afterwards. The flash is only
/// there to catch your eye the moment it appears.
enum NotchPulse {
    static let count = 3
    /// Down fast, back slowly — the asymmetry is what reads as a pulse rather
    /// than a blink.
    static let dip: TimeInterval = 0.14
    static let rise: TimeInterval = 0.26
    static var cycle: TimeInterval { dip + rise }
    /// 1.2s in total: long enough to be seen out of the corner of an eye,
    /// short enough that it is over before it becomes something to wait out.
    static var duration: TimeInterval { cycle * Double(count) }

    /// Not to zero. A glyph that disappears reads as a fault in the app; one
    /// that dims reads as the app insisting.
    static let dimmed: Double = 0.32
    /// Small on purpose. The ring around it does not move, so anything larger
    /// makes the glyph look loose inside it.
    static let swell: Double = 1.12

    /// Ease-out-quart. Real things decelerate; nothing here bounces.
    static let settle = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 1),
        endControlPoint: UnitPoint(x: 0.5, y: 1)
    )
    /// Ease-in, for the way down: the strike should arrive, not drift in.
    static let strike = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.4, y: 0),
        endControlPoint: UnitPoint(x: 1, y: 1)
    )

    // MARK: - Resolved

    // One beat, and a gentler one. Three sharp beats mean "look at this now";
    // a single soft swell means "that's done" — the difference has to be
    // audible at a glance or the green just reads as another alarm.

    /// Slower on the way up than the alert's strike: nothing is urgent here.
    static let resolvedRise: TimeInterval = 0.22
    static let resolvedFall: TimeInterval = 0.38
    static var resolvedDuration: TimeInterval { resolvedRise + resolvedFall }

    /// Brighter rather than dimmer. The alert flash *takes* light away, which
    /// reads as something failing; this gives a little, which reads as
    /// something completing.
    static let resolvedSwell: Double = 1.10
}

/// The two things the flash moves, in one animatable value.
struct AttentionPulseValues: Equatable {
    var opacity: Double = 1
    var scale: Double = 1
}

/// Plays `NotchPulse` once, whenever `trigger` changes to a new problem.
///
/// Nil trigger means nothing to say, and the content is passed through
/// untouched rather than wrapped in a stalled animator.
struct AttentionFlash: ViewModifier {
    let trigger: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Reduced motion loses the movement and nothing else: the red gradient
        // is already saying the same thing, and it says it without moving.
        if trigger == nil || reduceMotion {
            content
        } else {
            KeyframeAnimator(initialValue: AttentionPulseValues(), trigger: trigger) { values in
                content
                    .opacity(values.opacity)
                    .scaleEffect(values.scale)
            } keyframes: { _ in
                // Written out rather than looped. Three is the whole point of
                // the design, and a literal three lines is the one spelling
                // that cannot quietly become four.
                KeyframeTrack(\AttentionPulseValues.opacity) {
                    LinearKeyframe(NotchPulse.dimmed, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                    LinearKeyframe(NotchPulse.dimmed, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                    LinearKeyframe(NotchPulse.dimmed, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                }
                KeyframeTrack(\AttentionPulseValues.scale) {
                    LinearKeyframe(NotchPulse.swell, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                    LinearKeyframe(NotchPulse.swell, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                    LinearKeyframe(NotchPulse.swell, duration: NotchPulse.dip, timingCurve: NotchPulse.strike)
                    LinearKeyframe(1, duration: NotchPulse.rise, timingCurve: NotchPulse.settle)
                }
            }
        }
    }
}

/// One soft swell, when a problem has just been fixed.
///
/// Written out separately from `AttentionFlash` rather than sharing a
/// beat-count parameter. A keyframe track has to be spelled literally, so a
/// variable count would mean generating keyframes in a loop inside a result
/// builder for the sake of removing six lines — and the two are not the same
/// gesture anyway. One takes light away three times, the other gives a little
/// back once.
struct ResolvedPulse: ViewModifier {
    let trigger: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if trigger == nil || reduceMotion {
            content
        } else {
            KeyframeAnimator(initialValue: AttentionPulseValues(), trigger: trigger) { values in
                content
                    .opacity(values.opacity)
                    .scaleEffect(values.scale)
            } keyframes: { _ in
                KeyframeTrack(\AttentionPulseValues.scale) {
                    LinearKeyframe(NotchPulse.resolvedSwell,
                                   duration: NotchPulse.resolvedRise,
                                   timingCurve: NotchPulse.settle)
                    LinearKeyframe(1,
                                   duration: NotchPulse.resolvedFall,
                                   timingCurve: NotchPulse.settle)
                }
                // Opacity is held flat on purpose. The alert flash dims, and a
                // green that also dimmed would borrow the one signal that is
                // supposed to mean something is wrong.
                KeyframeTrack(\AttentionPulseValues.opacity) {
                    LinearKeyframe(1, duration: NotchPulse.resolvedDuration)
                }
            }
        }
    }
}

extension View {
    /// Flash three times, once, when `trigger` names a newly raised problem.
    func attentionFlash(trigger: String?) -> some View {
        modifier(AttentionFlash(trigger: trigger))
    }

    /// Swell once, when `trigger` names a problem that has just been fixed.
    func resolvedPulse(trigger: String?) -> some View {
        modifier(ResolvedPulse(trigger: trigger))
    }
}
