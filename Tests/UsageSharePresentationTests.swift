import XCTest
@testable import Codenotch

@MainActor
final class UsageSharePresentationTests: XCTestCase {
    private func report() -> UsageLedgerReport {
        UsageLedgerEngine.report(sessions: [], summary: UsageScanSummary(), days: 31,
                                 now: Date(), calendar: .current, timeline: UsageAccountTimeline())
    }

    func testClosingDuringLoadingCannotReopenThePopup() async {
        let presentation = UsageSharePresentation()
        let value = report()
        var pending: CheckedContinuation<UsageLedgerReport?, Never>?
        presentation.open { await withCheckedContinuation { pending = $0 } }
        while pending == nil { await Task.yield() }
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
        while first == nil { await Task.yield() }
        presentation.open(projectPath: "/second") { await withCheckedContinuation { second = $0 } }
        while second == nil { await Task.yield() }
        second?.resume(returning: value)
        while presentation.report == nil { await Task.yield() }
        first?.resume(returning: nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presentation.projectPath, "/second")
        XCTAssertEqual(presentation.report?.generatedAt, value.generatedAt)
        XCTAssertFalse(presentation.failed)
    }

    func testFailedLoadIsRecoverableAndSavingProtectsTheFrozenPreview() async {
        let presentation = UsageSharePresentation()
        presentation.open { nil }
        while !presentation.failed { await Task.yield() }
        XCTAssertTrue(presentation.isPresented)
        let value = report()
        presentation.open(projectPath: "/chosen") { value }
        while presentation.report == nil { await Task.yield() }
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
