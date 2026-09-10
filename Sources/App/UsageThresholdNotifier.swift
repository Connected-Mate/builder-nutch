import Foundation

/// Says something once when an account passes half, three quarters and 85% of a
/// limit window.
///
/// Three points and no more. The temptation is a notification every ten
/// percent, and it is the wrong instinct: the value of being told you are at
/// 75% comes entirely from it being rare enough that you look up. The notch
/// already carries the number continuously for anyone who wants to watch it.
///
/// Each threshold fires once per account, per window, per *window* — when the
/// limit rolls over, the slate is wiped and the same three points can be
/// crossed again on the next one. Crossing several at once, which happens when
/// a burst of work lands between two refreshes, produces one notification for
/// the highest, not three stacked on top of each other.
@MainActor
final class UsageThresholdNotifier {
    /// The three points the user asked to hear about.
    static let thresholds = [50, 75, 85]

    /// On by default. Someone paying for several subscriptions wants to know
    /// they are running one down; the switch is in Settings for when they do
    /// not.
    var isEnabled = true

    private let notifier: UserNotifying
    private var memory: [String: WindowMemory] = [:]

    /// What is remembered about one window between refreshes.
    private struct WindowMemory {
        /// The reset this window is counting down to. When it changes, this is
        /// a different window wearing the same id, and the record starts over.
        var resetsAt: Date?
        var fired: Set<Int>
        var lastPercent: Int
    }

    init(notifier: UserNotifying) {
        self.notifier = notifier
    }

    /// Look at the readings and post whatever has just been crossed.
    ///
    /// Returns what it posted, so the behaviour can be tested without a
    /// notification centre.
    @discardableResult
    func evaluate(snapshots: [ProviderSnapshot], now: Date) -> [UserNotice] {
        var posted: [UserNotice] = []
        var seen: Set<String> = []

        for snapshot in snapshots {
            for window in snapshot.windows {
                guard let fraction = window.usedFraction, fraction.isFinite else { continue }
                let key = "\(snapshot.id)|\(window.id)"
                seen.insert(key)
                // Floored, not rounded: 84.6% is not 85% yet, and a
                // notification that arrives before the number it names does is
                // the kind of small dishonesty that makes people stop trusting
                // the rest of the readings.
                let percent = min(100, max(0, Int((fraction * 100).rounded(.down))))

                // The first time this app lays eyes on a window is not an
                // event. This record lives in memory only, so every launch
                // starts blank: without this, opening Builder Nutch with three
                // accounts already past half would fire three notifications on
                // the spot, and again at the next launch, and the next. The
                // promise is "tell me when an account crosses 50%", not "tell
                // me it is above 50%", and the difference is the whole reason
                // this setting is safe to leave on.
                let isFirstSighting = memory[key] == nil
                var state = memory[key] ?? WindowMemory(resetsAt: window.resetsAt,
                                                        fired: [], lastPercent: percent)
                // A new window: either the vendor moved the reset, or the count
                // fell, which only happens when the limit rolled over.
                if state.resetsAt != window.resetsAt || percent < state.lastPercent {
                    state.fired = []
                }
                state.resetsAt = window.resetsAt
                state.lastPercent = percent

                let crossed = Self.thresholds.filter { percent >= $0 && !state.fired.contains($0) }
                // Marked whether or not anything is sent. Turning the setting
                // on should not fire for points that were passed while it was
                // off — that is history, not news.
                state.fired.formUnion(crossed)
                memory[key] = state

                guard isEnabled, !isFirstSighting, let highest = crossed.max() else { continue }
                let notice = Self.notice(
                    snapshot: snapshot, window: window, threshold: highest, now: now
                )
                notifier.post(notice)
                posted.append(notice)
            }
        }

        // An account that has gone away takes its record with it, so removing
        // and re-adding it behaves like the fresh start it looks like.
        memory = memory.filter { seen.contains($0.key) }
        return posted
    }

    static func notice(snapshot: ProviderSnapshot, window: LimitWindow,
                       threshold: Int, now: Date) -> UserNotice {
        let title = String(
            format: NSLocalizedString("%1$@ · %2$d%% used",
                                      comment: "Usage threshold notification title"),
            snapshot.displayName, threshold
        )
        var body = String(
            format: NSLocalizedString("%1$@ · %2$d%% left.",
                                      comment: "Usage threshold notification body"),
            window.label, max(0, 100 - threshold)
        )
        if let resetsAt = window.resetsAt {
            // A reset this app worked out from a sentence is marked as
            // approximate. A notification is read once, in passing, and acted
            // on — telling somebody their limit returns at a precise minute
            // that was in fact inferred is the sort of small confidence the
            // rest of these readings would not survive being caught at.
            body += " " + ResetCopy.text(for: resetsAt, now: now,
                                         derived: window.isResetDerived)
        }
        // The window's own reset is part of the id, so next week's 50% is a new
        // notification rather than one that silently replaces last week's in
        // Notification Centre — same identifier, same slot, and the earlier one
        // disappears without ever having been read.
        let stamp = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
        return UserNotice(id: "usage.\(snapshot.id).\(window.id).\(stamp).\(threshold)",
                          title: title, body: body)
    }
}
