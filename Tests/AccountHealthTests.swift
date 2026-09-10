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
        // The stand-in is well down, so handing back is worth the interruption.
        // The ceiling that governs that is covered separately.
        let states = [accounts[0].id: state(remaining: 98), accounts[1].id: state(remaining: 40)]
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

    func testAHealthyAccountIsNeverLeftForAFullerSibling() {
        let accounts = self.accounts(3)
        // The running account is comfortable; two siblings are fuller. Being
        // fuller is not a reason to move, only a reason to be chosen once
        // something else has already decided a move is needed.
        let states = [accounts[0].id: state(remaining: 60),
                      accounts[1].id: state(remaining: 95),
                      accounts[2].id: state(remaining: 99)]
        for preferred in [accounts[0].id, accounts[1].id, nil] {
            XCTAssertNil(AccountSelection.systemClaudeDecision(accounts: accounts, states: states,
                order: accounts.map(\.id), currentID: accounts[0].id, preferredID: preferred,
                thresholdPercent: 15, now: now), "A healthy account stays put")
        }
    }

    func testAForecastFromOneOrTwoReadingsCannotMoveTheLogin() {
        let accounts = self.accounts(2)
        let states = [accounts[0].id: state(remaining: 55), accounts[1].id: state(remaining: 95)]
        // Two readings four minutes apart, burning fast enough to look urgent.
        var thin = UsageForecast()
        thin.record(usedFraction: 0.45, at: now.addingTimeInterval(-240))
        thin.record(usedFraction: 0.85, at: now)
        XCTAssertFalse(thin.hasReliableTrend)
        XCTAssertNil(AccountSelection.systemClaudeDecision(accounts: accounts, states: states,
            order: accounts.map(\.id), currentID: accounts[0].id, preferredID: accounts[0].id,
            thresholdPercent: 15, forecasts: [accounts[0].id: thin], switchAheadMinutes: 20, now: now),
            "Two readings are not a trend, however alarming they look")

        // A third reading, five minutes of span: now it counts.
        var real = UsageForecast()
        for step in 0..<4 { real.record(usedFraction: 0.30 + 0.04 * Double(step * 3), at: now.addingTimeInterval(Double(step) * 180 - 540)) }
        XCTAssertTrue(real.hasReliableTrend)
        XCTAssertEqual(AccountSelection.systemClaudeDecision(accounts: accounts, states: states,
            order: accounts.map(\.id), currentID: accounts[0].id, preferredID: accounts[0].id,
            thresholdPercent: 15, forecasts: [accounts[0].id: real], switchAheadMinutes: 20, now: now)?.target.id,
            accounts[1].id)
    }

    func testAComfortableAccountKeepsRunningEvenWhenTheChosenOneComesBack() {
        let accounts = self.accounts(2)
        var recovered = UsageForecast()
        recovered.record(usedFraction: 0.97, at: now.addingTimeInterval(-600))
        recovered.record(usedFraction: 0.02, at: now.addingTimeInterval(-60))
        // Stand-in still has plenty: handing back now would be churn.
        let comfortable = [accounts[0].id: state(remaining: 98), accounts[1].id: state(remaining: 70)]
        XCTAssertNil(AccountSelection.systemClaudeDecision(accounts: accounts, states: comfortable,
            order: accounts.map(\.id), currentID: accounts[1].id, preferredID: accounts[0].id,
            thresholdPercent: 15, forecasts: [accounts[0].id: recovered], now: now))
        // Once the stand-in is well down, the chosen account takes over again.
        let worn = [accounts[0].id: state(remaining: 98), accounts[1].id: state(remaining: 40)]
        let decision = AccountSelection.systemClaudeDecision(accounts: accounts, states: worn,
            order: accounts.map(\.id), currentID: accounts[1].id, preferredID: accounts[0].id,
            thresholdPercent: 15, forecasts: [accounts[0].id: recovered], now: now)
        XCTAssertEqual(decision?.target.id, accounts[0].id)
        XCTAssertEqual(decision?.cause, .preferredReturned)
    }

    func testTheReasonNamesTheWindowThatActuallyRanOut() {
        let accounts = self.accounts(2)
        // Today's five-hour usage looks fine. The weekly limit is what is spent,
        // and that is the switch the person could not explain.
        var busy = ManagedAccountState(isConnected: true, windows: [
            LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 0.35, resetsAt: now.addingTimeInterval(3600)),
            LimitWindow(id: "seven_day", label: "Weekly limit", usedFraction: 0.88, resetsAt: now.addingTimeInterval(86_400))
        ], refreshedAt: now)
        busy.email = "person@example.test"
        let states = [accounts[0].id: busy, accounts[1].id: state(remaining: 95)]
        XCTAssertEqual(busy.bindingWindow?.label, "Weekly limit")
        XCTAssertEqual(busy.remainingPercent ?? -1, 12, accuracy: 0.001)
        let decision = AccountSelection.systemClaudeDecision(accounts: accounts, states: states,
            order: accounts.map(\.id), currentID: accounts[0].id, preferredID: accounts[0].id,
            thresholdPercent: 15, now: now)
        XCTAssertEqual(decision?.target.id, accounts[1].id)
        XCTAssertEqual(decision?.cause, .spent(remainingPercent: busy.remainingPercent ?? 0))
    }

    @MainActor
    func testADormantAccountNeverPinsTheBannerRed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dormant-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = AccountManager(rootURL: root)
        let first = try manager.add(provider: .claude, label: "Claude 1", emailHint: nil)
        let second = try manager.add(provider: .claude, label: "Claude 2", emailHint: nil)
        // Never signed in, and the person is in no hurry to. This is the shape
        // that kept the banner red no matter what they did to the live account.
        _ = try manager.add(provider: .codex, label: "Codex 1", emailHint: nil)
        for account in [first, second] {
            manager.applyState({ $0.isConnected = true
                $0.windows = [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 0.3, resetsAt: self.now.addingTimeInterval(3600))]
                $0.refreshedAt = Date() }, to: account.id)
        }
        XCTAssertNil(manager.attention, "A setup task is not an incident")
        XCTAssertEqual(manager.health.currentName, "Claude 1")
        XCTAssertEqual(manager.health.nextName, "Claude 2")
    }

    @MainActor
    func testFixingTheQueuedAccountClearsTheRedAndSaysSo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clears-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = AccountManager(rootURL: root)
        let first = try manager.add(provider: .claude, label: "Claude 1", emailHint: nil)
        let second = try manager.add(provider: .claude, label: "Claude 2", emailHint: nil)
        func connect(_ id: UUID) {
            manager.applyState({ $0.isConnected = true; $0.requiresSignIn = false
                $0.windows = [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 0.3, resetsAt: self.now.addingTimeInterval(3600))]
                $0.refreshedAt = Date() }, to: id)
        }
        connect(first.id)
        // Claude 2 is next in line and its saved login was revoked: a real fault.
        manager.applyState({ $0.requiresSignIn = true; $0.message = "expired" }, to: second.id)
        let raised = try XCTUnwrap(manager.attention)
        XCTAssertEqual(raised.kind, .reconnect)
        XCTAssertEqual(raised.accountID, second.id)

        connect(second.id)
        XCTAssertNil(manager.attention, "Fixing the problem must clear the red")
        let resolved = try XCTUnwrap(manager.resolvedAttention)
        XCTAssertEqual(resolved.kind, .reconnected)
        XCTAssertEqual(resolved.accountID, second.id)
        XCTAssertTrue(resolved.title.contains("Claude 2"))
    }

    @MainActor
    func testRemovingTheBrokenAccountIsNotReportedAsFixed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("removed-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = AccountManager(rootURL: root)
        let first = try manager.add(provider: .claude, label: "Claude 1", emailHint: nil)
        let second = try manager.add(provider: .claude, label: "Claude 2", emailHint: nil)
        manager.applyState({ $0.isConnected = true
            $0.windows = [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 0.3, resetsAt: self.now.addingTimeInterval(3600))]
            $0.refreshedAt = Date() }, to: first.id)
        manager.applyState({ $0.requiresSignIn = true }, to: second.id)
        XCTAssertEqual(manager.attention?.kind, .reconnect)

        try manager.remove(second)
        XCTAssertNil(manager.attention)
        XCTAssertNil(manager.resolvedAttention, "Deleting a problem is not solving it")
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

