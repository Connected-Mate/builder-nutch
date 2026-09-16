import XCTest
@testable import Codenotch

final class GenGenCertificateTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func report(_ tokens: Int, reached: Date? = nil, now: Date,
                        zone: String = "UTC") -> UsageLedgerReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        var session = UsageSessionDigest(sessionID: "private-account@example.org /private/project")
        session.tokens = UsageTokenTotals(input: tokens)
        if let reached {
            session.activityMinutes[String(Int(reached.timeIntervalSince1970 / 60))] =
                UsageTimeBucket(tokens: session.tokens, messages: 1)
        }
        var result = UsageLedgerReport(generatedAt: now, windowStart: now, windowEnd: now, days: 1,
            totalWeight: 0, tokens: UsageTokenTotals(input: 1), messages: 0, sessionCount: 0,
            accounts: [], timeline: [], scan: UsageScanSummary())
        result.calendar = calendar
        result.milestones = UsageMilestoneProgress(sessions: [session], now: now, calendar: calendar)
        return result
    }

    func testMissingHistoryAndLockedTotalsCannotExport() {
        let now = date("2026-09-16T12:00:00Z")
        XCTAssertThrowsError(try UsageGenGenCertificate(report: .empty, issuedAt: now))
        for total in [0, 9_999_999_999, 10_000_000_000, 99_999_999_999] {
            XCTAssertThrowsError(try UsageGenGenCertificate(report: report(total, now: now), issuedAt: now))
        }
    }

    func testObsidianUnknownDatesEncodeNullAndFixedPrivateContract() throws {
        let now = date("2026-09-16T12:00:00Z")
        let certificate = try UsageGenGenCertificate(report: report(100_000_000_000, now: now),
            issuedAt: now, id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let data = try certificate.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schema", "version", "id", "issuer", "achievement", "issuedAt",
            "totalTokens", "route", "graphiteReachedAt", "eligibleAt", "timeZone", "verification"]))
        XCTAssertEqual(object["schema"] as? String, "gengen-certificate")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["issuer"] as? String, "Builder Nutch")
        XCTAssertEqual(object["achievement"] as? String, "GenGen")
        XCTAssertEqual(object["route"] as? String, "obsidian")
        XCTAssertEqual(object["totalTokens"] as? Int, 100_000_000_000)
        XCTAssertEqual(object["verification"] as? String, "local-history")
        XCTAssertEqual(object["timeZone"] as? String, "GMT")
        XCTAssertTrue(object["graphiteReachedAt"] is NSNull)
        XCTAssertTrue(object["eligibleAt"] is NSNull)
        XCTAssertEqual(object["issuedAt"] as? String, "2026-09-16T12:00:00.000Z")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for privateField in ["private-account", "/private/project", "session", "email", "account"] {
            XCTAssertFalse(text.contains(privateField))
        }
    }

    func testCalendarMonthBoundaryMonthEndAndDST() throws {
        for (start, end, zone) in [
            ("2026-01-31T12:00:00Z", "2026-03-31T12:00:00Z", "UTC"),
            ("2023-12-31T12:00:00Z", "2024-02-29T12:00:00Z", "UTC"),
            ("2026-01-31T11:00:00Z", "2026-03-31T10:00:00Z", "Europe/Paris")
        ] {
            let reached = date(start), eligible = date(end)
            let before = report(10_000_000_000, reached: reached, now: eligible.addingTimeInterval(-1), zone: zone)
            XCTAssertThrowsError(try UsageGenGenCertificate(report: before, issuedAt: eligible))
            let at = report(10_000_000_000, reached: reached, now: eligible, zone: zone)
            let certificate = try UsageGenGenCertificate(report: at, issuedAt: eligible)
            XCTAssertEqual(certificate.route, "graphite-duration")
            XCTAssertEqual(certificate.graphiteReachedAt, reached)
            XCTAssertEqual(certificate.eligibleAt, eligible)
            XCTAssertEqual(certificate.eligibleAt, at.milestones?.genGen.reachedAt)
        }
    }

    func testObsidianRouteAndKnownEligibilityDate() throws {
        let now = date("2026-09-16T12:00:00Z"), reached = date("2026-01-01T12:00:00Z")
        let certificate = try UsageGenGenCertificate(
            report: report(100_000_000_000, reached: reached, now: now), issuedAt: now)
        XCTAssertEqual(certificate.route, "obsidian")
        XCTAssertEqual(certificate.eligibleAt, reached)
    }

    func testSafeIntegerBoundaryAndOverflowRejectRatherThanTruncate() throws {
        let now = date("2026-09-16T12:00:00Z")
        let safe = try UsageGenGenCertificate(report: report(UsageGenGenCertificate.maximumSafeTokens, now: now), issuedAt: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: safe.jsonData()) as? [String: Any])
        XCTAssertEqual(object["totalTokens"] as? Int, UsageGenGenCertificate.maximumSafeTokens)
        for total in [UsageGenGenCertificate.maximumSafeTokens + 1, Int.max] {
            XCTAssertThrowsError(try UsageGenGenCertificate(report: report(total, now: now), issuedAt: now))
        }
    }

    func testFutureReportCannotExport() {
        let now = date("2026-09-16T12:00:00Z")
        XCTAssertThrowsError(try UsageGenGenCertificate(
            report: report(100_000_000_000, now: now.addingTimeInterval(60)), issuedAt: now))
    }

    func testNonPortableFixedOffsetTimeZoneIsRejected() {
        let now = date("2026-09-16T12:00:00Z")
        var fixed = report(100_000_000_000, now: now)
        fixed.calendar?.timeZone = TimeZone(secondsFromGMT: 7_200)!
        XCTAssertThrowsError(try UsageGenGenCertificate(report: fixed, issuedAt: now))
    }

    func testNonGregorianReportCannotUnlockBeforePortableCalendarDate() throws {
        let graphite = date("2026-07-16T12:00:00Z")
        let now = date("2026-09-14T12:00:00Z")
        var value = report(10_000_000_000, reached: graphite, now: now)
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(secondsFromGMT: 0)!
        value.calendar = hebrew
        XCTAssertTrue(value.milestones!.genGen(at: now, calendar: hebrew).reached)
        XCTAssertThrowsError(try UsageGenGenCertificate(report: value, issuedAt: now))
        let portableDate = date("2026-09-16T12:00:00Z")
        var later = report(10_000_000_000, reached: graphite, now: portableDate)
        later.calendar = hebrew
        XCTAssertNoThrow(try UsageGenGenCertificate(report: later, issuedAt: portableDate))
    }

    func testSyntheticFixtureWritesAsImportableJSON() throws {
        let now = date("2026-09-15T12:00:00Z")
        let certificate = try UsageGenGenCertificate(report: report(10_000_000_000,
            reached: date("2026-07-15T12:00:00Z"), now: now), issuedAt: now,
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        // Synthetic contract fixture only; never real saved usage.
        let url = URL(fileURLWithPath: "/tmp/gengen-native-synthetic-certificate.json")
        let data = try certificate.jsonData()
        try data.write(to: url, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
