import XCTest
@testable import Codenotch

final class UsageChartPresentationTests: XCTestCase {
    func testAbsentDaysStayInOrderAndHaveExactlyZeroHeight() {
        let tokens = UsageTokenTotals(input: 100, output: 20, thinking: 10,
                                      measurements: 1, inputMeasurements: 1, outputMeasurements: 1)
        let slice = UsageDaySlice(day: "2026-09-14", weight: 0, sharePercent: 0, tokens: tokens, messages: 1)
        let days = UsageChartDay.make(keys: ["2026-09-13", "2026-09-14", "2026-09-15"],
                                     timeline: [slice], partialHistory: false)
        XCTAssertEqual(days.map(\.id), ["2026-09-13", "2026-09-14", "2026-09-15"])
        XCTAssertEqual(days.map { $0.tokens.total }, [0, 120, 0])
        XCTAssertEqual(days.map { $0.fraction(of: 120) }, [0, 1, 0])
        XCTAssertEqual(days[0].availability, .complete)
        XCTAssertEqual(days[0].fraction(of: 0), 0)
    }

    func testPartialHistoryDoesNotTurnUnreportedFieldsIntoMeasurements() {
        XCTAssertEqual(UsageChartDay.availability(.unavailable, partialHistory: true), .unavailable)
        XCTAssertEqual(UsageChartDay.availability(.complete, partialHistory: true), .partial)
        XCTAssertEqual(UsageChartDay.availability(.partial, partialHistory: false), .partial)
        let days = UsageChartDay.make(keys: ["2026-09-15"], timeline: [], partialHistory: true)
        XCTAssertEqual(days[0].availability, .partial)
        XCTAssertEqual(days[0].tokens.total, 0)
    }

    func testUnreportedOutputMakesRecordedTotalALowerBound() {
        let tokens = UsageTokenTotals(input: 100, measurements: 1, inputMeasurements: 1)
        XCTAssertEqual(UsageChartDay.totalAvailability(tokens, partialHistory: false), .partial)
    }

    func testSmallNonzeroDaysRetainTheirTrueProportionWithoutMinimumBarHeight() {
        let day = UsageChartDay(id: "2026-09-15", tokens: UsageTokenTotals(input: 1), availability: .complete)
        XCTAssertEqual(day.fraction(of: 1_000), 0.001, accuracy: 0.000001)
        XCTAssertEqual(day.fraction(of: -1), 0)
    }

    func testMissingClaudeCacheMakesInputAndTotalLowerBounds() {
        let tokens = UsageTokenTotals(input: 100, output: 20, measurements: 1,
                                      inputMeasurements: 1, outputMeasurements: 1, claudeMeasurements: 1)
        XCTAssertEqual(UsageChartDay.inputAvailability(tokens), .partial)
        XCTAssertEqual(UsageChartDay.totalAvailability(tokens, partialHistory: false), .partial)
        XCTAssertEqual(tokens.total, 120)
    }

    func testCodexInclusiveInputStaysExactWithoutCacheBreakdown() {
        let tokens = UsageTokenTotals(input: 100, output: 20, measurements: 1,
                                      inputMeasurements: 1, outputMeasurements: 1, codexMeasurements: 1)
        XCTAssertEqual(UsageChartDay.inputAvailability(tokens), .complete)
        XCTAssertEqual(UsageChartDay.totalAvailability(tokens, partialHistory: false), .complete)
        XCTAssertEqual(tokens.coverage.cacheRead, .unavailable)
    }

    func testUnreportedActiveInputIsNotAZeroMeasurement() {
        let tokens = UsageTokenTotals(output: 20, measurements: 1, outputMeasurements: 1)
        XCTAssertEqual(UsageChartDay.inputAvailability(tokens), .unavailable)
        XCTAssertEqual(UsageChartDay.totalAvailability(tokens, partialHistory: false), .partial)
        XCTAssertEqual(UsageChartDay.totalAvailability(UsageTokenTotals(), partialHistory: false), .complete)
    }
}
