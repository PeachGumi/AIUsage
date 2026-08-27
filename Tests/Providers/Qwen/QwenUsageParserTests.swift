import XCTest
@testable import AIUsage

final class QwenUsageParserTests: XCTestCase {
    func testCombinesSubscriptionQuotaAndUsageResponses() throws {
        let subscription = Data(#"{"data":{"DataV2":{"data":{"data":{"specCode":"pro","status":"ACTIVE","remainingDays":10}}}}}"#.utf8)
        let quota = Data(#"{"data":{"DataV2":{"data":{"data":{"pro":{"five_hour":1000,"weekly":5000}}}}}}"#.utf8)
        let usage = Data(#"{"data":{"DataV2":{"data":{"data":{"per5HourPercentage":0.25,"per1WeekPercentage":0.4,"per5HourResetTime":1787793000000,"per1WeekResetTime":1788319500000}}}}}"#.utf8)

        let snapshot = try QwenUsageParser.parse(
            subscription: subscription,
            quota: quota,
            usage: usage,
            now: Date(timeIntervalSince1970: 7))

        XCTAssertEqual(snapshot.provider, .qwen)
        XCTAssertEqual(snapshot.planName, "Token Plan Pro · 10 days left")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 40])
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 7))
    }

    func testRejectsMissingPlanQuotaAndOutOfRangeFraction() {
        let subscription = Data(#"{"data":{"DataV2":{"data":{"data":{"specCode":"pro","status":"ACTIVE","remainingDays":1}}}}}"#.utf8)
        let missingQuota = Data(#"{"data":{"DataV2":{"data":{"data":{}}}}}"#.utf8)
        let invalidUsage = Data(#"{"data":{"DataV2":{"data":{"data":{"per5HourPercentage":1.2,"per1WeekPercentage":0.1,"per5HourResetTime":1,"per1WeekResetTime":1}}}}}"#.utf8)

        XCTAssertThrowsError(try QwenUsageParser.parse(
            subscription: subscription,
            quota: missingQuota,
            usage: invalidUsage))
    }

    func testClassifiesSuccessfulEmptySubscriptionAsNoActivePlan() {
        let emptySubscription = Data(#"{"data":{"DataV2":{"data":{"success":true,"code":"SUCCESS","msg":"Success."}}}}"#.utf8)
        let unused = Data(#"{}"#.utf8)

        XCTAssertThrowsError(try QwenUsageParser.parse(
            subscription: emptySubscription,
            quota: unused,
            usage: unused)) { error in
                XCTAssertEqual(error as? QwenUsageError, .noActiveSubscription)
            }
    }
}
