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

    func testUsesLabelsWhenUpstreamReordersUsageCards() throws {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"Monthly","value":"33%"},{"label":"5-hour limit","value":"11%"},{"label":"Weekly usage","value":"22%"}],"promo":false,"other":false,"useBalance":false}"#

        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [11, 22, 33])
    }

    func testAmbiguousPartiallyRecognizedLabelsFailClosed() {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"Monthly","value":"33%"},{"label":"Current limit","value":"11%"},{"label":"Weekly usage","value":"22%"}],"promo":false,"other":false,"useBalance":false}"#

        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: json)) { error in
            XCTAssertEqual(error as? OpenCodeGoError, .invalidResponse)
        }
    }

    func testUnlabeledLegacyPayloadRetainsPositionalFallback() throws {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"11%"},{"value":"22%"},{"value":"33%"}],"promo":false,"other":false,"useBalance":false}"#

        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [11, 22, 33])
    }

    func testRejectsMalformedAndOutOfRangePercentages() {
        let malformed = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"oops"},{"value":"32.1%"}]}"#
        let outOfRange = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"0.1%"},{"value":"101%"}]}"#

        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: malformed))
        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: outOfRange))
    }
}
