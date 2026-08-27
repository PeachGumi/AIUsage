import XCTest
@testable import AIUsage

final class UsageSeverityTests: XCTestCase {
    func testSeverityBoundariesMatchProductRules() {
        XCTAssertEqual(UsageSeverity(remainingPercent: 50.1), .healthy)
        XCTAssertEqual(UsageSeverity(remainingPercent: 50), .warning)
        XCTAssertEqual(UsageSeverity(remainingPercent: 20.1), .warning)
        XCTAssertEqual(UsageSeverity(remainingPercent: 20), .critical)
        XCTAssertEqual(UsageSeverity(remainingPercent: 0), .critical)
    }
}
