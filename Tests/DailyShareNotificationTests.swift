import XCTest
@testable import Codenotch

private final class RecordingDailyShareNotificationBackend: DailyShareNotificationBacking {
    var status: DailyShareNotificationAuthorization = .allowed
    var statusCompletions: [(DailyShareNotificationAuthorization) -> Void] = []
    var authorizationCompletions: [(Bool) -> Void] = []
    var requests: [DailyShareNotificationRequest] = []
    var addCompletions: [(Error?) -> Void] = []
    var removalCount = 0
    var delaysStatus = false

    func dailyShareAuthorizationStatus(
        then completion: @escaping (DailyShareNotificationAuthorization) -> Void
    ) {
        if delaysStatus { statusCompletions.append(completion) }
        else { completion(status) }
    }

    func requestDailyShareAuthorization(then completion: @escaping (Bool) -> Void) {
        authorizationCompletions.append(completion)
    }

    func replaceDailyShareRequest(
        _ request: DailyShareNotificationRequest,
        completion: @escaping (Error?) -> Void
    ) {
        requests.append(request)
        addCompletions.append(completion)
    }

    func removeDailyShareRequest() { removalCount += 1 }
}

@MainActor
final class DailyShareNotificationSchedulerTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testAllowedReminderUsesOnePrivateDailyLocalTimeRequest() async throws {
        let backend = RecordingDailyShareNotificationBackend()
        let scheduler = DailyShareNotificationScheduler(backend: backend)

        scheduler.setEnabled(true)
        await drainMainQueue()

        let request = try XCTUnwrap(backend.requests.only)
        XCTAssertEqual(request.id, DailyShareNotificationScheduler.requestID)
        XCTAssertEqual(request.hour, 17)
        XCTAssertEqual(request.minute, 30)
        XCTAssertFalse(request.title.localizedCaseInsensitiveContains("account"))
        XCTAssertFalse(request.body.localizedCaseInsensitiveContains("project"))
        XCTAssertEqual(backend.removalCount, 1)
    }

    func testOnlyDailyReminderRoutesToShareAndExistingNoticesStayOnAccounts() {
        XCTAssertEqual(
            SystemNotifier.activationDestination(
                for: DailyShareNotificationScheduler.requestID
            ),
            .dailyShare
        )
        XCTAssertEqual(
            SystemNotifier.activationDestination(for: "switch.existing-notice"),
            .accounts
        )
    }

    func testDeniedReminderIsRemovedAndNotScheduled() async {
        let backend = RecordingDailyShareNotificationBackend()
        backend.status = .denied
        let scheduler = DailyShareNotificationScheduler(backend: backend)
        var denied = false
        scheduler.onAuthorizationDeniedChange = { denied = $0 }

        scheduler.setEnabled(true)
        await drainMainQueue()

        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(backend.removalCount, 1)
        XCTAssertTrue(denied)
    }

    func testUndeterminedPermissionSchedulesOnlyAfterConsent() async {
        let backend = RecordingDailyShareNotificationBackend()
        backend.status = .notDetermined
        let scheduler = DailyShareNotificationScheduler(backend: backend)

        scheduler.setEnabled(true)
        await drainMainQueue()
        XCTAssertTrue(backend.requests.isEmpty)

        backend.authorizationCompletions.only?(true)
        await drainMainQueue()
        XCTAssertEqual(backend.requests.count, 1)
    }

    func testOptOutWinsAgainstLateAuthorizationCallback() async {
        let backend = RecordingDailyShareNotificationBackend()
        backend.delaysStatus = true
        let scheduler = DailyShareNotificationScheduler(backend: backend)

        scheduler.setEnabled(true)
        scheduler.setEnabled(false)
        backend.statusCompletions.first?(.allowed)
        await drainMainQueue()

        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(backend.removalCount, 2)
    }

    func testOptOutClearsDeniedFeedback() async {
        let backend = RecordingDailyShareNotificationBackend()
        backend.status = .denied
        let scheduler = DailyShareNotificationScheduler(backend: backend)
        var deniedStates: [Bool] = []
        scheduler.onAuthorizationDeniedChange = { deniedStates.append($0) }

        scheduler.setEnabled(true)
        await drainMainQueue()
        scheduler.setEnabled(false)

        XCTAssertEqual(deniedStates, [true, false])
    }

    func testOptOutRemovesRequestAgainWhenAnAddFinishesLate() async {
        let backend = RecordingDailyShareNotificationBackend()
        let scheduler = DailyShareNotificationScheduler(backend: backend)
        scheduler.setEnabled(true)
        await drainMainQueue()
        XCTAssertEqual(backend.requests.count, 1)

        scheduler.setEnabled(false)
        backend.addCompletions.only?(nil)
        await drainMainQueue()

        XCTAssertEqual(backend.removalCount, 3)
    }
}

@MainActor
final class DailyShareNotificationPreferenceTests: XCTestCase {
    func testReminderDefaultsOnAndPersistsOptOut() {
        let suite = "DailyShareNotificationPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = Preferences(defaults: defaults)
        XCTAssertTrue(initial.dailyShareReminder)
        initial.dailyShareReminder = false

        XCTAssertFalse(Preferences(defaults: defaults).dailyShareReminder)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
