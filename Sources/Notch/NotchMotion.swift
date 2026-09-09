import SwiftUI

/// The motion vocabulary, in one place so the whole surface moves like one thing.
///
/// Springs rather than eased curves throughout: macOS motion reads as physical
/// because things overshoot slightly and settle, and a panel that scales without
/// any of that feels like a slideshow. The numbers are chosen to be *just* under
/// bouncy — `dampingFraction` in the high 0.7s gives a single soft settle rather
/// than a wobble.
enum NotchMotion {
    /// Folding open and shut. Long enough to read as a movement, short enough
    /// that it never delays you.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// Contents arriving after the shape has started opening.
    static let contents = Animation.spring(response: 0.36, dampingFraction: 0.82)

    /// The tooltip travelling between cells. Slower and more damped than the
    /// fold: it is a bigger object moving a longer way, and the same spring that
    /// feels crisp on a 10pt pill feels abrupt on a 226pt card.
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)

    /// Contents changing inside something that is already moving. Short, and an
    /// ease rather than a spring — a spring on a crossfade has nothing to
    /// overshoot and just arrives late.
    static let crossfade = Animation.easeInOut(duration: 0.16)

    /// A percentage changing under you. Slower on purpose: a ring that snaps to a
    /// new value reads as a glitch, one that sweeps reads as a measurement.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)

    /// The settings arc being taken back into the notch.
    ///
    /// Quicker than `unfold` and with no delay, which is the whole point: on
    /// the staggered spring the arc lagged the fold, so the notch began closing
    /// first and the arc appeared to leave with the screen edge instead of
    /// being absorbed. It has to be inside the black while there is still black
    /// to be inside. Eased *in* because a thing being drawn into a mass
    /// accelerates as it goes.
    static let merge = Animation.easeIn(duration: 0.2)

    /// The red arriving in the notch, and leaving it again.
    ///
    /// An ease rather than a spring, and the one place in this file that is:
    /// a colour has no mass and nothing to overshoot, and a spring on it just
    /// makes the red arrive late. Ease-out-quart, so it comes on quickly and
    /// settles — the notch should already be red by the time you have looked
    /// across at it, without anything having flashed on.
    static let alertRaise = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.4)

    /// Each cell trails the one above it, so the stack unfurls rather than
    /// appearing all at once. Capped so a long list never feels sluggish.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// Everything above, unless the system has been asked for less movement.
    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}
