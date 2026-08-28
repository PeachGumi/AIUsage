import XCTest
@testable import AIUsage

final class MajorProviderTests: XCTestCase {
    func testUsageWindowAllowsIndependentLanesWithSameCadence() throws {
        let first = try UsageWindow(
            id: "first-weekly",
            kind: .weekly,
            label: "First weekly",
            compactLabel: "W1",
            usedPercent: 10,
            resetsAt: nil,
            resetDescription: nil)
        let second = try UsageWindow(
            id: "second-weekly",
            kind: .weekly,
            label: "Second weekly",
            compactLabel: "W2",
            usedPercent: 20,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = ProviderSnapshot(provider: .antigravity, planName: nil, windows: [first, second], fetchedAt: Date())

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(Set(snapshot.windows.map(\.id)), Set(["first-weekly", "second-weekly"]))
        XCTAssertEqual(MenuBarPresentation.title(snapshot: snapshot, metric: .remaining), "AG W1:90% / W2:80%")
    }

    func testClaudeParsesFiveHourAndWeeklyOAuthWindows() throws {
        let data = Data(#"{"five_hour":{"utilization":23.5,"resets_at":"2026-08-28T08:00:00Z"},"seven_day":{"utilization":41,"resets_at":"2026-09-01T00:00:00Z"}}"#.utf8)
        let credential = ClaudeCredential(
            accessToken: "fixture-token",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            scopes: ["user:profile"],
            subscriptionType: "pro",
            rateLimitTier: nil)

        let snapshot = try ClaudeProvider.parseUsage(data: data, credential: credential, now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [23.5, 41])
    }

    func testClaudeFailsClosedWhenNoKnownWindowsExist() {
        let credential = ClaudeCredential(
            accessToken: "fixture-token",
            expiresAt: nil,
            scopes: [],
            subscriptionType: nil,
            rateLimitTier: nil)

        XCTAssertThrowsError(try ClaudeProvider.parseUsage(data: Data(#"{"future_window":{"utilization":10}}"#.utf8), credential: credential))
    }

    func testAntigravityParsesTwoQuotaFamiliesAndCadences() throws {
        let data = Data(#"{
          "groups":[
            {"displayName":"Gemini Models","buckets":[
              {"bucketId":"gemini-5h","displayName":"5-hour Limit","remaining":{"remainingFraction":0.91},"resetTime":"2026-08-28T12:00:00Z"},
              {"bucketId":"gemini-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.82}}
            ]},
            {"displayName":"Claude and GPT models","buckets":[
              {"bucketId":"third-session","displayName":"Session","remaining":{"case":"remainingFraction","value":0.73}},
              {"bucketId":"third-weekly","displayName":"Weekly Limit","remaining":{"remainingFraction":0.64}}
            ]}
          ]
        }"#.utf8)

        let snapshot = try AntigravityProvider.parseQuotaSummary(data: data)

        XCTAssertEqual(snapshot.windows.map(\.id), [
            "antigravity-gemini-fiveHour",
            "antigravity-thirdparty-fiveHour",
            "antigravity-gemini-weekly",
            "antigravity-thirdparty-weekly",
        ])
        XCTAssertEqual(snapshot.windows.map { $0.remainingPercent.rounded() }, [91, 73, 82, 64])
    }

    func testAntigravityRejectsUnknownOnlyQuotaShape() {
        let data = Data(#"{"groups":[{"displayName":"Future Models","buckets":[{"bucketId":"daily","remaining":{"remainingFraction":0.9}}]}]}"#.utf8)
        XCTAssertThrowsError(try AntigravityProvider.parseQuotaSummary(data: data))
    }

    func testAntigravityCSRFTokenParsingSupportsBothArgumentForms() {
        XCTAssertEqual(AntigravityProvider.csrfToken(from: "/app/language_server --csrf_token abc123 --other"), "abc123")
        XCTAssertEqual(AntigravityProvider.csrfToken(from: "/app/language_server --csrf_token=xyz789"), "xyz789")
        XCTAssertNil(AntigravityProvider.csrfToken(from: "/app/language_server"))
    }

    func testCopilotParsesDirectQuotaSnapshots() throws {
        let data = Data(#"{
          "copilot_plan":"pro",
          "token_based_billing":false,
          "quota_reset_date":"2026-09-01",
          "quota_snapshots":{
            "premium_interactions":{"entitlement":1000,"remaining":750,"percent_remaining":75,"quota_id":"premium"},
            "chat":{"entitlement":500,"remaining":400,"percent_remaining":80,"quota_id":"chat"}
          }
        }"#.utf8)

        let snapshot = try CopilotProvider.parseUsage(data: data)

        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 25])
        XCTAssertEqual(Set(snapshot.windows.map(\.label)), Set(["AI credits / premium", "Chat"]))
    }

    func testCopilotSupportsLegacyMonthlyQuotaFallbackWithoutInventingMissingDenominators() throws {
        let valid = Data(#"{
          "copilot_plan":"individual",
          "monthly_quotas":{"chat":100,"completions":200},
          "limited_user_quotas":{"chat":25,"completions":100}
        }"#.utf8)
        let snapshot = try CopilotProvider.parseUsage(data: valid)
        XCTAssertEqual(Set(snapshot.windows.map(\.usedPercent)), Set([50, 75]))

        let invalid = Data(#"{"copilot_plan":"individual","limited_user_quotas":{"chat":25}}"#.utf8)
        XCTAssertThrowsError(try CopilotProvider.parseUsage(data: invalid))
    }

    func testCursorParsesIndependentMonthlyPools() throws {
        let data = Data(#"{
          "billingCycleEnd":"2026-09-15T00:00:00Z",
          "membershipType":"pro",
          "individualUsage":{"plan":{"used":1200,"limit":2000,"autoPercentUsed":12.5,"apiPercentUsed":42,"totalPercentUsed":60}}
        }"#.utf8)

        let snapshot = try CursorProvider.parseUsage(data: data)

        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Included plan", "Cursor Models", "Other Models"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60, 12.5, 42])
    }

    func testCursorRejectsMissingPlanInsteadOfShowingZero() {
        XCTAssertThrowsError(try CursorProvider.parseUsage(data: Data(#"{"membershipType":"pro"}"#.utf8)))
    }

    func testZAIParsesOnlyRecognizedCodingPlanTokenWindows() throws {
        let data = Data(#"{
          "success":true,"code":200,
          "data":{"planName":"Lite","limits":[
            {"type":"TOKENS_LIMIT","unit":5,"number":300,"percentage":25,"nextResetTime":1787900000000},
            {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":40,"nextResetTime":1788000000000},
            {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":70}
          ]}
        }"#.utf8)

        let snapshot = try ZAIProvider.parseUsage(data: data)

        XCTAssertEqual(snapshot.planName, "Lite")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 40])
    }

    func testZAIFailsClosedForUnknownTokenCadence() {
        let data = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":12,"percentage":10}]}}"#.utf8)
        XCTAssertThrowsError(try ZAIProvider.parseUsage(data: data))
    }

    func testKimiParsesWeeklyAndRollingFiveHourQuota() throws {
        let data = Data(#"{
          "usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-09-01T00:00:00Z"},
          "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-08-28T13:00:00Z"}}]
        }"#.utf8)

        let snapshot = try KimiProvider.parseUsage(data: data)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 69.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows.last?.usedPercent ?? 0, 214.0 / 2048.0 * 100, accuracy: 0.0001)
    }

    func testKimiRejectsResponseWithoutUsableQuota() {
        XCTAssertThrowsError(try KimiProvider.parseUsage(data: Data(#"{"usage":{"limit":"0","used":"0"},"limits":[]}"#.utf8)))
    }
}
