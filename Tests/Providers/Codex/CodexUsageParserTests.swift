import XCTest
@testable import AIUsage

final class CodexUsageParserTests: XCTestCase {
    func testMapsExactFiveHourAndWeeklyWindows() throws {
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":82,"reset_at":1787793027,"limit_window_seconds":18000},"secondary_window":{"used_percent":16,"reset_at":1788319550,"limit_window_seconds":604800}}}"#

        let snapshot = try CodexUsageParser.parse(data: Data(json.utf8), now: Date(timeIntervalSince1970: 9))

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [82, 16])
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 9))
    }

    func testMapsMonthlyWindowForGoPlan() throws {
        let json = #"{"plan_type":"go","rate_limit":{"primary_window":{"used_percent":10,"reset_at":1790494198,"limit_window_seconds":2592000},"secondary_window":null}}"#

        let snapshot = try CodexUsageParser.parse(data: Data(json.utf8))

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.planName, "Go")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.monthly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [10])
    }

    func testRejectsUnknownDurationsAndInvalidPercentages() {
        let unknown = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1,"limit_window_seconds":32400}}}"#
        let invalid = #"{"rate_limit":{"primary_window":{"used_percent":101,"reset_at":1,"limit_window_seconds":18000}}}"#

        XCTAssertThrowsError(try CodexUsageParser.parse(data: Data(unknown.utf8)))
        XCTAssertThrowsError(try CodexUsageParser.parse(data: Data(invalid.utf8)))
    }
}
