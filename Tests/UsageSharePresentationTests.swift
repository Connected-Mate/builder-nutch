import XCTest
@testable import Codenotch

@MainActor
final class UsageSharePresentationTests: XCTestCase {
    private func report() -> UsageLedgerReport {
        UsageLedgerEngine.report(sessions: [], summary: UsageScanSummary(), days: 31,
                                 now: Date(), calendar: .current, timeline: UsageAccountTimeline())
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "The expected presentation state did not arrive")
    }

    func testClosingDuringLoadingCannotReopenThePopup() async {
        let presentation = UsageSharePresentation()
        let value = report()
        var pending: CheckedContinuation<UsageLedgerReport?, Never>?
        presentation.open { await withCheckedContinuation { pending = $0 } }
        await waitFor { pending != nil }
        XCTAssertTrue(presentation.isPresented)
        presentation.close()
        pending?.resume(returning: value)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(presentation.report)
    }

    func testNewRequestWinsOverEarlierProjectLoad() async {
        let presentation = UsageSharePresentation()
        let value = report()
        var first: CheckedContinuation<UsageLedgerReport?, Never>?
        var second: CheckedContinuation<UsageLedgerReport?, Never>?
        presentation.open(projectPath: "/first") { await withCheckedContinuation { first = $0 } }
        await waitFor { first != nil }
        let firstID = presentation.requestID
        presentation.open(projectPath: "/second") { await withCheckedContinuation { second = $0 } }
        await waitFor { second != nil }
        XCTAssertNotEqual(presentation.requestID, firstID)
        second?.resume(returning: value)
        await waitFor { presentation.report != nil }
        first?.resume(returning: nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presentation.projectPath, "/second")
        XCTAssertEqual(presentation.report?.generatedAt, value.generatedAt)
        XCTAssertFalse(presentation.failed)
    }

    func testFailedLoadIsRecoverableAndSavingProtectsTheFrozenPreview() async {
        let presentation = UsageSharePresentation()
        presentation.open { nil }
        await waitFor { presentation.failed }
        XCTAssertTrue(presentation.isPresented)
        let value = report()
        presentation.open(projectPath: "/chosen") { value }
        await waitFor { presentation.report != nil }
        presentation.isSaving = true
        presentation.close()
        presentation.open { nil }
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.projectPath, "/chosen")
        XCTAssertEqual(presentation.report?.generatedAt, value.generatedAt)
        presentation.isSaving = false
        presentation.close()
        XCTAssertFalse(presentation.isPresented)
    }
}
