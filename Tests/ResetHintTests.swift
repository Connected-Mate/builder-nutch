import XCTest
@testable import Codenotch

/// Kimi's server writes the reset time as a sentence and never as a timestamp.
/// Reading that sentence is allowed; guessing at one we cannot read is not.
final class ResetHintTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// 2 days, 6 hours and 36 minutes: the weekly hint observed on this Mac.
    private let weekly: TimeInterval = 196_560

    private func seconds(_ hint: String) -> TimeInterval? {
        ResetHint.date(from: hint, now: now)?.timeIntervalSince(now)
    }

    func testTheStringsThisMacActuallyReturns() {
        // Observed live on this Mac: the weekly summary and the 5h window.
        XCTAssertEqual(seconds("resets in 2d 6h 36m"), weekly)
        XCTAssertEqual(seconds("resets in 36m"), 2_160)
    }

    func testTheOtherWaysAVendorWritesADuration() {
        XCTAssertEqual(seconds("in 3 hours"), 10_800)
        XCTAssertEqual(seconds("1 week 2 days"), 777_600)
        XCTAssertEqual(seconds("45 minutes"), 2_700)
        XCTAssertEqual(seconds("2h30m"), 9_000)
        XCTAssertEqual(seconds("Resets in 90 SECONDS"), 90)
    }

    func testAClockTimeBecomesItsNextOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // 1_800_000_000 is 2027-01-15 08:00:00 UTC.
        let sameDay = try XCTUnwrap(ResetHint.date(from: "resets at 14:00", now: now, calendar: calendar))
        XCTAssertEqual(sameDay.timeIntervalSince(now), 21_600)
        // A time already past today rolls to tomorrow rather than into the past.
        let tomorrow = try XCTUnwrap(ResetHint.date(from: "resets at 2:30 am", now: now, calendar: calendar))
        XCTAssertEqual(tomorrow.timeIntervalSince(now), 66_600)
    }

    func testAnAbsoluteStampIsUsedAsWritten() throws {
        let stamp = try XCTUnwrap(ResetHint.date(from: "resets at 2027-01-15T20:00:00Z", now: now))
        XCTAssertEqual(stamp.timeIntervalSince(now), 43_200)
        XCTAssertNotNil(ResetHint.date(from: "2027-01-16T08:00:00.500Z", now: now))
    }

    func testASentenceWeCannotReadYieldsNoTimeAtAll() {
        for hint in ["soon", "resets tomorrow", "when the moon is full", "", "   ",
                     "resets in a while", "resets in 3 fortnights", "resets in 2 days and a bit",
                     "resets in 5 hours or so, maybe 6"] {
            XCTAssertNil(ResetHint.date(from: hint, now: now), "\(hint) is not a duration this app can read")
        }
        XCTAssertNil(ResetHint.date(from: 3_600, now: now), "Only text is a hint")
        XCTAssertNil(ResetHint.date(from: nil, now: now))
    }

    func testATimeInThePastOrAbsurdlyFarAheadIsRefused() {
        XCTAssertNil(ResetHint.date(from: "resets in 0m", now: now), "A window resetting now has no countdown to show")
        XCTAssertNil(ResetHint.date(from: "resets in 200 days", now: now))
        XCTAssertNil(ResetHint.date(from: "resets at 2020-01-01T00:00:00Z", now: now))
        XCTAssertNil(ResetHint.date(from: String(repeating: "1d ", count: 200), now: now))
    }

    func testKimiWindowsCarryTheDerivedTimeAndSayItIsDerived() throws {
        let auth: [String: Any] = ["ready": true, "managed_provider": ["name": "managed:kimi-code", "status": "authenticated"]]
        let usage: [String: Any] = [
            "kind": "ok",
            "summary": ["label": "Weekly limit", "used": 1, "limit": 100, "reset_hint": "resets in 2d 6h 36m"],
            "limits": [["label": "5h limit", "used": 3, "limit": 100, "reset_hint": "resets in 36m"]]
        ]
        let state = try KimiAccountIntegration.state(auth: auth, usage: usage, now: now)
        XCTAssertEqual(state.windows.count, 2)
        let window = try XCTUnwrap(state.windows.first)
        XCTAssertEqual(window.resetsAt?.timeIntervalSince(now), weekly)
        XCTAssertTrue(window.isResetDerived)
        XCTAssertEqual(state.windows[1].resetsAt?.timeIntervalSince(now), 2_160)
        // The countdown says it is approximate rather than posing as exact.
        XCTAssertEqual(ResetCopy.text(for: try XCTUnwrap(state.windows[1].resetsAt), now: now, derived: true), "Resets in ~36 min")
        XCTAssertEqual(ResetCopy.text(for: try XCTUnwrap(state.windows[1].resetsAt), now: now), "Resets in 36 min")
    }

    func testARealTimestampIsPreferredAndNeverMarkedDerived() throws {
        let auth: [String: Any] = ["ready": true, "managed_provider": ["name": "managed:kimi-code", "status": "authenticated"]]
        let usage: [String: Any] = ["kind": "ok", "limits": [[
            "label": "5h limit", "used": 3, "limit": 100,
            "reset_at": now.addingTimeInterval(600).timeIntervalSince1970, "reset_hint": "resets in 2d"
        ]]]
        let window = try XCTUnwrap(KimiAccountIntegration.state(auth: auth, usage: usage, now: now).windows.first)
        XCTAssertEqual(window.resetsAt?.timeIntervalSince(now), 600)
        XCTAssertFalse(window.isResetDerived)
    }
}
