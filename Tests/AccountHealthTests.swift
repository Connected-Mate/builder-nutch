import XCTest
@testable import Codenotch

/// The rules that decide when the Mac login moves on, and what the accounts
/// window says is wrong. No real account, keychain or network is touched.
final class AccountHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func accounts(_ count: Int) -> [ManagedAccount] {
        (0..<count).map { index in
            ManagedAccount(id: UUID(), provider: .claude, label: "Claude \(index + 1)",
                           createdAt: now.addingTimeInterval(Double(index)))
        }
    }

    private func state(remaining: Double) -> ManagedAccountState {
        ManagedAccountState(isConnected: true,
            windows: [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 1 - remaining / 100,
                                  resetsAt: now.addingTimeInterval(3600))], refreshedAt: now)
    }

    /// A window burning `rate` of itself per minute, sampled every three minutes.
    private func burning(from used: Double, rate: Double) -> UsageForecast {
        var forecast = UsageForecast()
        for step in 0..<4 {
            forecast.record(usedFraction: used + rate * Double(step * 3), at: now.addingTimeInterval(Double(step) * 180 - 540))
        }
        return forecast
    }

    func testForecastSwitchesBeforeTheQuotaFloorIsReached() {
        let accounts = self.accounts(2)
        let states = [accounts[0].id: state(remaining: 55), accounts[1].id: state(remaining: 90)]
        // 4 % of the window per minute: about eight minutes of work left.
        let forecasts = [accounts[0].id: burning(from: 0.33, rate: 0.04)]
        XCTAssertNil(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15, now: now),
            "Without a measured trend, 55 % remaining is not a reason to move")
        XCTAssertEqual(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15,
            forecasts: forecasts, switchAheadMinutes: 20, now: now)?.id, accounts[1].id)
        XCTAssertNil(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15,
            forecasts: forecasts, switchAheadMinutes: 5, now: now),
            "A shorter notice must not move an account that still has eight minutes")
    }

    func testASlowlyBurningAccountIsLeftAlone() {
        let accounts = self.accounts(2)
        let states = [accounts[0].id: state(remaining: 55), accounts[1].id: state(remaining: 90)]
        let forecasts = [accounts[0].id: burning(from: 0.44, rate: 0.001)]
        XCTAssertNil(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15,
            forecasts: forecasts, switchAheadMinutes: 20, now: now))
    }

    func testTheSwitchPrefersTheFullestAccountAndKeepsTheChosenOrderOnATie() {
        let accounts = self.accounts(4)
        let states = [accounts[0].id: state(remaining: 5), accounts[1].id: state(remaining: 30),
                      accounts[2].id: state(remaining: 95), accounts[3].id: state(remaining: 95)]
        XCTAssertEqual(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15, now: now)?.id,
            accounts[2].id, "The fullest account buys the most working time")
        let tied = [accounts[0].id: state(remaining: 5), accounts[1].id: state(remaining: 95),
                    accounts[2].id: state(remaining: 95), accounts[3].id: state(remaining: 95)]
        XCTAssertEqual(AccountSelection.systemClaude(accounts: accounts, states: tied, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15, now: now)?.id,
            accounts[1].id, "Equal quotas keep the order the person arranged")
    }

    func testThePreferredAccountTakesItsPlaceBackOnceItsWindowHasRolledOver() {
        let accounts = self.accounts(2)
        let states = [accounts[0].id: state(remaining: 98), accounts[1].id: state(remaining: 70)]
        var recovered = UsageForecast()
        recovered.record(usedFraction: 0.97, at: now.addingTimeInterval(-600))
        recovered.record(usedFraction: 0.02, at: now.addingTimeInterval(-60))
        // Running on the stand-in, with the person's chosen account queued next.
        XCTAssertNil(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[1].id, preferredID: accounts[0].id, thresholdPercent: 15, now: now),
            "A healthy stand-in is not disturbed while the chosen account is still spent")
        XCTAssertEqual(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[1].id, preferredID: accounts[0].id, thresholdPercent: 15,
            forecasts: [accounts[0].id: recovered], now: now)?.id, accounts[0].id)
    }

    func testAForecastSwitchNeverHandsTheAccountBackToItself() {
        let accounts = self.accounts(1)
        let states = [accounts[0].id: state(remaining: 60)]
        XCTAssertNil(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[0].id, preferredID: accounts[0].id, thresholdPercent: 15,
            forecasts: [accounts[0].id: burning(from: 0.36, rate: 0.05)], switchAheadMinutes: 20, now: now),
            "The only account cannot be replaced by itself")
    }

    @MainActor
    func testTheQueuedAccountThatNeedsSigningInIsTheOneReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = AccountManager(rootURL: root)
        let first = try manager.add(provider: .claude, label: "Claude 1", emailHint: nil)
        let second = try manager.add(provider: .claude, label: "Claude 2", emailHint: nil)
        let third = try manager.add(provider: .claude, label: "Claude 3", emailHint: nil)
        try manager.select(first)
        manager.updateHealth()

        let reconnect = try XCTUnwrap(manager.attention)
        XCTAssertEqual(reconnect.kind, .reconnect)
        XCTAssertEqual(reconnect.accountID, second.id, "The account the next switch would use comes first")
        XCTAssertTrue(reconnect.title.contains("Claude 2"))
        XCTAssertEqual(reconnect.actionTitle, NSLocalizedString("Reconnect", comment: ""))
        XCTAssertFalse(manager.health.isSwitchReady)
        XCTAssertEqual(manager.health.currentName, "Claude 1")
        XCTAssertEqual(manager.health.nextName, "Claude 2")
        XCTAssertTrue(manager.healthSummary.contains("Claude 1"))

        // A blocked Keychain outranks a queued account that needs signing in.
        manager.applyState({ $0.requiresKeychainAccess = true }, to: third.id)
        let blocked = try XCTUnwrap(manager.attention)
        XCTAssertEqual(blocked.kind, .keychainAccess)
        XCTAssertEqual(blocked.accountID, third.id)
        XCTAssertEqual(blocked.actionTitle, NSLocalizedString("Allow access", comment: ""))
    }
}

