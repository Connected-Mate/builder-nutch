import Foundation

/// The hour of grace between the notch going red and macOS being asked to say
/// something out loud.
///
/// The order matters and is the whole design: the notch goes red immediately
/// and quietly, because that is a signal you can ignore while you are in the
/// middle of something. A notification is not — it takes the screen and it
/// takes your place in whatever you were doing. So it is the second thing that
/// happens, not the first, and only when the quiet signal has demonstrably been
/// ignored for an hour.
///
/// Three conditions have to hold at the deadline: the same problem is still
/// standing, it has never been escalated before, and the accounts window has
/// not been opened since it was raised. Opening that window is what counts as
/// having seen it — not fixing it. Somebody who has looked at the problem and
/// decided to deal with it later does not need to be told about it again.
@MainActor
final class AttentionEscalator {
    /// One hour.
    static let defaultDelay: TimeInterval = 60 * 60

    private let notifier: UserNotifying
    private let delay: TimeInterval
    private let clock: () -> Date

    private var alert: NotchAlert?
    /// Problems already escalated. One notification per problem, ever.
    private var escalated: Set<String> = []
    /// When the accounts window was last brought up.
    private var lastOpenedAccounts: Date?
    private var timer: Timer?

    init(notifier: UserNotifying,
         delay: TimeInterval = AttentionEscalator.defaultDelay,
         clock: @escaping () -> Date = Date.init) {
        self.notifier = notifier
        self.delay = delay
        self.clock = clock
    }

    deinit { timer?.invalidate() }

    /// The problem standing right now, or nil for none.
    func update(_ alert: NotchAlert?) {
        guard alert?.id != self.alert?.id else { return }
        self.alert = alert
        reschedule()
    }

    /// The person has looked at the accounts window. Whatever was raised before
    /// this moment has been seen.
    func accountsWindowOpened(at date: Date? = nil) {
        lastOpenedAccounts = date ?? clock()
        reschedule()
    }

    /// Whether the standing problem has waited long enough, evaluated at
    /// `now`. Returns what was posted, so a test can check the copy without
    /// waiting an hour or owning a notification centre.
    @discardableResult
    func evaluate(now: Date) -> UserNotice? {
        guard let alert, !escalated.contains(alert.id) else { return nil }
        guard now.timeIntervalSince(alert.raisedAt) >= delay else { return nil }
        if let lastOpenedAccounts, lastOpenedAccounts >= alert.raisedAt { return nil }
        escalated.insert(alert.id)
        let notice = UserNotice(
            id: "attention." + alert.id,
            title: alert.title,
            body: alert.detail
        )
        notifier.post(notice)
        Log.usage.info("escalated attention \(alert.id, privacy: .public)")
        return notice
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One shot, fired at the deadline itself.
    ///
    /// Not a poll and not a repeating tick: there is exactly one instant at
    /// which this can become true, and it is known the moment the problem is
    /// raised. Anything else would be the app waking up every minute for an
    /// hour to ask a question whose answer it already had.
    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let alert, !escalated.contains(alert.id) else { return }
        if let lastOpenedAccounts, lastOpenedAccounts >= alert.raisedAt { return }

        let due = alert.raisedAt.addingTimeInterval(delay)
        guard due.timeIntervalSince(clock()) > 0 else {
            // Already overdue — a problem that outlived a relaunch, say, since
            // `raisedAt` is when it started rather than when we heard of it.
            evaluate(now: clock())
            return
        }
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.evaluate(now: self.clock())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
