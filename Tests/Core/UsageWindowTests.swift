import XCTest
@testable import AIUsage

final class UsageWindowTests: XCTestCase {
    func testValidPercentageCalculatesRemaining() throws {
        let window = try UsageWindow(
            kind: .fiveHour,
            label: "5-hour",
            usedPercent: 32.1,
            resetsAt: nil,
            resetDescription: nil)

        XCTAssertEqual(window.remainingPercent, 67.9, accuracy: 0.0001)
    }

    func testRejectsNonFiniteAndOutOfRangePercentages() {
        for value in [Double.nan, .infinity, -0.1, 100.1] {
            XCTAssertThrowsError(try UsageWindow(
                kind: .weekly,
                label: "Weekly",
                usedPercent: value,
                resetsAt: nil,
                resetDescription: nil))
        }
    }
}
