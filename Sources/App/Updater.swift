import Foundation
import Sparkle

/// Keeps the app up to date on its own.
///
/// Silent by design: `SUAutomaticallyUpdate` and `SUEnableAutomaticChecks` in
/// the Info.plist mean Sparkle checks, downloads and installs without asking,
/// and without the first-launch permission prompt it otherwise shows. For an
/// agent app with no windows that is the only sensible behaviour — there is no
/// natural moment to interrupt someone who never looks at it.
///
/// Two things it still cannot do silently, which is macOS rather than Sparkle:
/// the app has to be writable by the user installing the update (true for a
/// normal drag to /Applications, false if it was copied there with `sudo`), and
/// the replacement is applied on relaunch rather than mid-flight.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the last check came to, in words the settings sheet can show.
    ///
    /// Sparkle's own answer to a failed check is a modal saying "an error
    /// occurred in retrieving update information" — true, and useless: it names
    /// no cause and offers nothing to do. Keeping the outcome here lets the one
    /// place a user goes to think about updates say what actually happened.
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle:          return nil
            case .checking:      return "Checking…"
            case .upToDate:      return "Builder Nutch is up to date."
            case .found(let v):  return "Version \(v) is available and will install shortly."
            case .unreachable:
                // The one people actually hit, and the one Sparkle's wording
                // hides: nothing is wrong with the app or the machine.
                return "Couldn't reach the update server. Builder Nutch will try "
                     + "again on its own — nothing is wrong with this copy."
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle

    /// A fork must never install the upstream maintainer's release over itself.
    /// Enable updates only after this distribution has its own signed feed.
    var isAvailable: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else { return false }
        return !key.isEmpty
    }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    /// Mirrors the preference, so switching it off really does stop the checks
    /// rather than only hiding them.
    var automatic: Bool {
        get { isAvailable && controller.updater.automaticallyChecksForUpdates }
        set {
            guard isAvailable else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var lastChecked: Date? { isAvailable ? controller.updater.lastUpdateCheckDate : nil }

    /// Starts the scheduled checks. Deliberately not in `init`: the controller
    /// is lazy so that `self` exists before it is handed over as the delegate.
    func start() { if isAvailable { _ = controller } }

    /// The manual path, for someone who does not want to wait for the schedule.
    /// This one *does* show UI — it was asked for, so silence would read as a
    /// broken button.
    func checkNow() {
        guard isAvailable else { return }
        outcome = .checking
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.outcome = .upToDate(Date()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.outcome = .found(version) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in
            // A feed that cannot be fetched is the ordinary failure — offline,
            // or the server is down — and it is not the user's problem to
            // solve. Anything else is reported as itself.
            self.outcome = Self.isUnreachable(code)
                ? .unreachable
                : .failed(error.localizedDescription)
        }
    }

    /// Sparkle folds every "could not load the feed" case into one code.
    static func isUnreachable(_ code: Int) -> Bool {
        code == Int(SUError.appcastError.rawValue)
    }
}
