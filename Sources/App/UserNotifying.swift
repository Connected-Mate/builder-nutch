import Foundation
import UserNotifications

/// One thing macOS should say out loud.
struct UserNotice: Equatable {
    /// Stable and unique per event. Posting the same id twice replaces rather
    /// than stacks, which is what is wanted everywhere this is used: a repeat
    /// here is always a mistake, never a second thing worth reading.
    let id: String
    let title: String
    let body: String
}

/// Posting a macOS notification, behind a protocol so tests never reach the
/// real notification centre.
///
/// Not fastidiousness. `UNUserNotificationCenter.current()` traps outright in a
/// process whose bundle it does not like, and the unit tests run inside the app
/// host precisely so they can touch app types — one call from a test and the
/// whole suite goes down with it.
protocol UserNotifying: AnyObject {
    func post(_ notice: UserNotice)
}

/// The real notification centre.
///
/// Authorisation is asked for on the first notice rather than at launch, and
/// that is a deliberate difference from what most apps do. An app that demands
/// permission to interrupt you before it has ever had anything to say gets told
/// no, and the one moment this app genuinely needs to interrupt — an account
/// that has been broken for an hour — is the moment it would find the door shut.
/// Asked at the point of a real message, the request explains itself.
final class SystemNotifier: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    /// Run when the user clicks one of these notifications. The click is the
    /// whole point of sending it: it has to land on the problem.
    var onActivate: (() -> Void)?

    private var center: UNUserNotificationCenter?

    /// Resolved lazily and kept, so `current()` is touched once and only by a
    /// process that has actually decided to notify somebody.
    private func connectedCentre() -> UNUserNotificationCenter {
        if let center { return center }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        return center
    }

    func post(_ notice: UserNotice) {
        let center = connectedCentre()
        authorize(center) { granted in
            guard granted else {
                Log.usage.info("notification suppressed: not authorised")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            // No trigger: now, not on a schedule. The waiting was done before
            // this was ever called.
            let request = UNNotificationRequest(
                identifier: notice.id, content: content, trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Log.usage.error("notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func authorize(_ center: UNUserNotificationCenter,
                           then body: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                body(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Log.usage.error("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
                    }
                    body(granted)
                }
            case .denied:
                // Refused once is refused. Asking again is what the system
                // prompt exists to prevent, and the notch is still red.
                body(false)
            @unknown default:
                body(false)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even when Builder Nutch is the app in front. Being frontmost is
    /// not the same as being looked at: the notch lives at the edge of a screen
    /// somebody is using for something else.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let activate = onActivate
        DispatchQueue.main.async { activate?() }
        completionHandler()
    }
}
