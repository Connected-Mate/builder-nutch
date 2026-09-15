import Foundation

enum DailyShareNotificationAuthorization: Equatable {
    case allowed
    case denied
    case notDetermined
}

struct DailyShareNotificationRequest: Equatable {
    let id: String
    let title: String
    let body: String
    let hour: Int
    let minute: Int
}

/// Narrow seam around Notification Centre. Tests use a recording backend, so
/// they never ask macOS for notification permission or alter pending notices.
protocol DailyShareNotificationBacking: AnyObject {
    func dailyShareAuthorizationStatus(
        then completion: @escaping (DailyShareNotificationAuthorization) -> Void
    )
    func requestDailyShareAuthorization(then completion: @escaping (Bool) -> Void)
    func replaceDailyShareRequest(
        _ request: DailyShareNotificationRequest,
        completion: @escaping (Error?) -> Void
    )
    func removeDailyShareRequest()
}

extension SystemNotifier: DailyShareNotificationBacking {}

/// Keeps exactly one repeating local-time request in macOS. A revision guards
/// callbacks from a permission prompt or add operation that finished after the
/// user changed the switch.
@MainActor
final class DailyShareNotificationScheduler {
    static let requestID = "builder-nutch.daily-usage-share"

    private let backend: DailyShareNotificationBacking
    private var enabled = false
    private var revision: UInt = 0
    var onAuthorizationDeniedChange: ((Bool) -> Void)?

    init(backend: DailyShareNotificationBacking) {
        self.backend = backend
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        revision &+= 1
        let requestedRevision = revision

        // The stable identifier makes this both cancellation and de-duplication.
        backend.removeDailyShareRequest()
        guard enabled else {
            onAuthorizationDeniedChange?(false)
            return
        }

        backend.dailyShareAuthorizationStatus { [weak self] status in
            DispatchQueue.main.async {
                self?.continueScheduling(status: status, revision: requestedRevision)
            }
        }
    }

    /// Re-checks permission after returning from System Settings and refreshes
    /// the calendar request after a clock or time-zone change.
    func refresh() {
        setEnabled(enabled)
    }

    private func continueScheduling(
        status: DailyShareNotificationAuthorization,
        revision requestedRevision: UInt
    ) {
        guard requestedRevision == revision, enabled else { return }
        onAuthorizationDeniedChange?(status == .denied)
        switch status {
        case .allowed:
            schedule(revision: requestedRevision)
        case .denied:
            break
        case .notDetermined:
            backend.requestDailyShareAuthorization { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          requestedRevision == self.revision,
                          self.enabled else { return }
                    self.onAuthorizationDeniedChange?(!granted)
                    guard granted else { return }
                    self.schedule(revision: requestedRevision)
                }
            }
        }
    }

    private func schedule(revision requestedRevision: UInt) {
        let request = DailyShareNotificationRequest(
            id: Self.requestID,
            title: NSLocalizedString(
                "Your daily token share is ready",
                comment: "Daily share notification title"
            ),
            body: NSLocalizedString(
                "Open Builder Nutch to preview it before sharing.",
                comment: "Daily share notification body"
            ),
            hour: 17,
            minute: 30
        )
        backend.replaceDailyShareRequest(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Log.usage.error("daily share notification failed: \(error.localizedDescription, privacy: .public)")
                }
                // A late add after opt-out must not resurrect the reminder.
                if requestedRevision != self.revision && !self.enabled {
                    self.backend.removeDailyShareRequest()
                }
            }
        }
    }
}
