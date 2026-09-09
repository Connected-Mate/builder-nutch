import XCTest
@testable import Codenotch

final class UsageForecastTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func forecast(_ readings: [(TimeInterval, Double)]) -> UsageForecast {
        var forecast = UsageForecast()
        for (minutes, used) in readings { forecast.record(usedFraction: used, at: start.addingTimeInterval(minutes * 60)) }
        return forecast
    }

    func testShortHistoryRefusesToGuessABurnRate() {
        XCTAssertNil(UsageForecast().burnRate)
        XCTAssertNil(forecast([(0, 0.1)]).burnRate, "One reading cannot describe a rate")
        XCTAssertNil(forecast([(0, 0.1), (1, 0.2)]).burnRate, "Two readings one minute apart are noise")
        XCTAssertNil(forecast([(0, 0.1), (2, 0.2), (4, 0.3)]).burnRate, "Under five minutes is still noise")
        XCTAssertNil(forecast([(0, 0.4), (3, 0.4), (6, 0.4)]).burnRate, "A flat window is not burning")
        XCTAssertNil(forecast([(0, 0.4), (3, 0.4), (6, 0.4)]).minutesUntilExhausted(at: start))
    }

    func testBurnRateAndPredictedExhaustionFollowTheReadings() throws {
        // One percent of the window per minute: sixty minutes of history left.
        let steady = forecast([(0, 0.10), (3, 0.13), (6, 0.16), (9, 0.19)])
        XCTAssertEqual(try XCTUnwrap(steady.burnRate), 0.01, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(steady.minutesUntilExhausted(at: start.addingTimeInterval(9 * 60))), 81, accuracy: 0.5)
        // The estimate keeps ageing between refreshes rather than freezing.
        XCTAssertEqual(try XCTUnwrap(steady.minutesUntilExhausted(at: start.addingTimeInterval(29 * 60))), 61, accuracy: 0.5)
        XCTAssertEqual(steady.minutesUntilExhausted(at: start.addingTimeInterval(600 * 60)), 0)
    }

    func testAReadingThatDipsStopsThePredictingUntilANewTrendExists() {
        // A window that goes backwards has rolled over, or the vendor disagreed
        // with itself. Either way the earlier samples describe something that is
        // no longer true, so no rate is claimed until fresh readings agree.
        let dipped = forecast([(0, 0.10), (3, 0.11), (6, 0.30), (9, 0.13), (12, 0.14)])
        XCTAssertNil(dipped.burnRate)
        XCTAssertNil(dipped.minutesUntilExhausted(at: start.addingTimeInterval(12 * 60)))
        XCTAssertEqual(dipped.samples.count, 2)
    }

    func testOneLargeStepIsSmoothedRatherThanTreatedAsTheNewRate() throws {
        let stepped = forecast([(0, 0.10), (3, 0.11), (6, 0.12), (9, 0.13), (12, 0.40)])
        let rate = try XCTUnwrap(stepped.burnRate)
        // The step alone would read as 9 % of the window per minute.
        XCTAssertLessThan(rate, 0.03)
        XCTAssertGreaterThan(try XCTUnwrap(stepped.minutesUntilExhausted(at: start.addingTimeInterval(12 * 60))), 20)
    }

    func testRolledOverWindowClearsHistoryAndIsRecordedAsRecovery() {
        var forecast = self.forecast([(0, 0.90), (3, 0.94), (6, 0.98)])
        XCTAssertNil(forecast.recoveredAt)
        forecast.record(usedFraction: 0.02, at: start.addingTimeInterval(9 * 60))
        XCTAssertEqual(forecast.recoveredAt, start.addingTimeInterval(9 * 60))
        XCTAssertEqual(forecast.samples.map(\.usedFraction), [0.02], "Spent-window samples would predict a rate that never happened")
        XCTAssertNil(forecast.burnRate)
    }

    func testAPartlyUsedWindowDroppingIsNotTreatedAsARecovery() {
        var forecast = self.forecast([(0, 0.20), (3, 0.24)])
        forecast.record(usedFraction: 0.05, at: start.addingTimeInterval(6 * 60))
        XCTAssertNil(forecast.recoveredAt, "Only a window that was nearly spent can have rolled over")
        XCTAssertEqual(forecast.samples.count, 1)
    }

    func testHistoryStaysBoundedAndIgnoresOutOfOrderOrBrokenReadings() {
        var forecast = UsageForecast()
        for index in 0..<40 { forecast.record(usedFraction: Double(index) / 100, at: start.addingTimeInterval(Double(index) * 60)) }
        XCTAssertEqual(forecast.samples.count, UsageForecast.capacity)
        XCTAssertEqual(forecast.samples.last?.usedFraction, 0.39)
        let unchanged = forecast.samples
        forecast.record(usedFraction: 0.5, at: start)
        forecast.record(usedFraction: .nan, at: start.addingTimeInterval(10_000))
        forecast.record(usedFraction: .infinity, at: start.addingTimeInterval(10_000))
        XCTAssertEqual(forecast.samples, unchanged)
        forecast.record(usedFraction: 7, at: start.addingTimeInterval(10_000))
        XCTAssertEqual(forecast.samples.last?.usedFraction, 1, "A usage reading above the limit is still just spent")
    }

    func testHeadroomReadsLikeAClock() {
        XCTAssertEqual(UsageForecast.headroom(minutes: 0), "1 min")
        XCTAssertEqual(UsageForecast.headroom(minutes: 45.4), "45 min")
        XCTAssertEqual(UsageForecast.headroom(minutes: 120), "2 h")
        XCTAssertEqual(UsageForecast.headroom(minutes: 190), "3 h 10")
        XCTAssertNil(UsageForecast.headroom(minutes: .nan))
        XCTAssertNil(UsageForecast.headroom(minutes: -5))
    }
}
