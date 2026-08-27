import XCTest
@testable import AIUsage

final class OpenCodeGoParserTests: XCTestCase {
    func testParsesFractionalWindowsAndWorkspaceID() throws {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"5-hour","value":"0.2%","reset":"resets soon"},{"label":"Weekly","value":"0.1%","reset":"resets Friday"},{"label":"Monthly","value":"32.1%","reset":"resets Sep 1"}],"promo":false,"other":false,"useBalance":true}"#

        let result = try OpenCodeGoParser.parse(jsonText: json, now: Date(timeIntervalSince1970: 11))

        XCTAssertEqual(result.workspaceID, "wrk_example")
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [0.2, 0.1, 32.1])
        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.fetchedAt, Date(timeIntervalSince1970: 11))
    }

    func testRejectsMalformedAndOutOfRangePercentages() {
        let malformed = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"oops"},{"value":"32.1%"}]}"#
        let outOfRange = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"0.1%"},{"value":"101%"}]}"#

        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: malformed))
        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: outOfRange))
    }
}
