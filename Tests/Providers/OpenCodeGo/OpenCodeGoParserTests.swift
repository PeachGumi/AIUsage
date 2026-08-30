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

    func testParsedNinetyNinePointNineRemainingTransitionTriggersRecovery() throws {
        let partialJSON = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"5-hour","value":"0.1%"},{"label":"Weekly","value":"20%"},{"label":"Monthly","value":"30%"}],"promo":false,"other":false,"useBalance":false}"#
        let recoveredJSON = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"5-hour","value":"0%"},{"label":"Weekly","value":"20%"},{"label":"Monthly","value":"30%"}],"promo":false,"other":false,"useBalance":false}"#
        let partial = try OpenCodeGoParser.parse(jsonText: partialJSON).snapshot
        let recovered = try OpenCodeGoParser.parse(jsonText: recoveredJSON).snapshot
        let instance = ProviderInstance(provider: .openCodeGo)
        var detector = QuotaRecoveryDetector()

        let partialFiveHour = try XCTUnwrap(partial.windows.first { $0.kind == .fiveHour })
        XCTAssertEqual(partialFiveHour.usedPercent, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(partialFiveHour.remainingPercent, 99.9, accuracy: 0.000_001)
        XCTAssertTrue(detector.observe(
            snapshots: [instance.id: partial],
            instanceLookup: { $0 == instance.id ? instance : nil }).isEmpty)

        let events = detector.observe(
            snapshots: [instance.id: recovered],
            instanceLookup: { $0 == instance.id ? instance : nil })

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.provider, .openCodeGo)
        XCTAssertEqual(events.first?.windowKind, .fiveHour)
        XCTAssertEqual(events.first?.message, "5時間利用量が回復しました！")
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

    func testAPIUsageParserProvidesUsedPercentAndResetDates() throws {
        let data = Data(#"{"usage":{"rolling":{"status":"ok","percent":0.1,"resetsAt":"2026-09-01T00:00:30.000Z"},"weekly":{"status":"ok","percent":20,"resetsAt":"2026-09-03T00:00:00Z"},"monthly":{"status":"ok","percent":30,"resetsAt":"2026-10-01T00:00:00Z"}}}"#.utf8)
        let now = Date(timeIntervalSince1970: 123)

        let snapshot = try OpenCodeGoAPIUsageParser.parse(data: data, now: now)

        XCTAssertEqual(snapshot.provider, .openCodeGo)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0.1, 20, 30])
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 99.9, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(
            snapshot.windows.first?.resetsAt,
            ISO8601DateFormatter().date(from: "2026-09-01T00:00:30Z"))
    }

    func testAPIUsageParserRejectsInvalidPercentAndResetDate() {
        let invalidPercent = Data(#"{"usage":{"rolling":{"percent":101,"resetsAt":"2026-09-01T00:00:30Z"},"weekly":{"percent":20,"resetsAt":"2026-09-03T00:00:00Z"},"monthly":{"percent":30,"resetsAt":"2026-10-01T00:00:00Z"}}}"#.utf8)
        let invalidDate = Data(#"{"usage":{"rolling":{"percent":1,"resetsAt":"soon"},"weekly":{"percent":20,"resetsAt":"2026-09-03T00:00:00Z"},"monthly":{"percent":30,"resetsAt":"2026-10-01T00:00:00Z"}}}"#.utf8)

        XCTAssertThrowsError(try OpenCodeGoAPIUsageParser.parse(data: invalidPercent))
        XCTAssertThrowsError(try OpenCodeGoAPIUsageParser.parse(data: invalidDate))
    }

    @MainActor
    func testAPIRequestIsPinnedToHTTPSOpenCodeUsageEndpoint() throws {
        let request = try OpenCodeGoAPIClient.makeRequest(apiKey: "  secret-key  ")

        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "opencode.ai")
        XCTAssertEqual(request.url?.path, "/zen/go/v1/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    @MainActor
    func testAPIRequestRejectsBlankKey() {
        XCTAssertThrowsError(try OpenCodeGoAPIClient.makeRequest(apiKey: "  \n ")) { error in
            XCTAssertEqual(error as? OpenCodeGoAPIError, .missingKey)
        }
    }

    func testRecoveryPlannerTreatsFirstProbeAsBaseline() throws {
        let current = try apiSnapshot(fiveHourUsed: 0, resetAfter: 60)
        XCTAssertFalse(OpenCodeGoRecoveryPlanner.didRecover(previous: nil, current: current))
    }

    func testRecoveryPlannerDetectsPartialToFullTransition() throws {
        let previous = try apiSnapshot(fiveHourUsed: 0.1, resetAfter: 30)
        let current = try apiSnapshot(fiveHourUsed: 0, resetAfter: 18_000)

        XCTAssertTrue(OpenCodeGoRecoveryPlanner.didRecover(previous: previous, current: current))
    }

    func testRecoveryPlannerDoesNotTreatPartialImprovementAsRecovery() throws {
        let previous = try apiSnapshot(fiveHourUsed: 0.2, resetAfter: 30)
        let current = try apiSnapshot(fiveHourUsed: 0.1, resetAfter: 30)

        XCTAssertFalse(OpenCodeGoRecoveryPlanner.didRecover(previous: previous, current: current))
    }

    func testRecoveryPlannerChecksJustAfterNearbyReset() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try apiSnapshot(fiveHourUsed: 10, resetAfter: 30, now: now)

        XCTAssertEqual(
            OpenCodeGoRecoveryPlanner.nextDelay(snapshot: snapshot, now: now),
            32,
            accuracy: 0.001)
    }

    func testRecoveryPlannerCapsFarResetAtNormalInterval() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try apiSnapshot(fiveHourUsed: 10, resetAfter: 3_600, now: now)

        XCTAssertEqual(
            OpenCodeGoRecoveryPlanner.nextDelay(snapshot: snapshot, now: now),
            300,
            accuracy: 0.001)
    }

    func testRecoveryPlannerNeverSchedulesImmediateTightLoop() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try apiSnapshot(fiveHourUsed: 10, resetAfter: -60, now: now)

        XCTAssertEqual(
            OpenCodeGoRecoveryPlanner.nextDelay(snapshot: snapshot, now: now),
            5,
            accuracy: 0.001)
    }

    func testAmbientCredentialUsesEnvironmentForDefaultOpenCodeCard() {
        let instance = ProviderInstance(
            id: ProviderInstance.legacyID(for: .openCodeGo),
            provider: .openCodeGo)

        let key = OpenCodeGoAmbientCredentialLoader.apiKey(
            for: instance,
            environment: ["OPENCODE_API_KEY": "  env-key  "],
            homeDirectory: URL(fileURLWithPath: "/definitely/not/used"))

        XCTAssertEqual(key, "env-key")
    }

    func testAmbientCredentialNeverLeaksToDuplicateCard() {
        let instance = ProviderInstance(provider: .openCodeGo)
        XCTAssertFalse(instance.isDefaultSlot)

        let key = OpenCodeGoAmbientCredentialLoader.apiKey(
            for: instance,
            environment: ["OPENCODE_API_KEY": "env-key"],
            homeDirectory: URL(fileURLWithPath: "/definitely/not/used"))

        XCTAssertNil(key)
    }

    func testAmbientCredentialParsesOnlyOpenCodeAPIAuthEntry() {
        let api = Data(#"{"opencode":{"type":"api","key":" secret "},"openai":{"type":"api","key":"other"}}"#.utf8)
        let oauth = Data(#"{"opencode":{"type":"oauth","access":"token","refresh":"refresh","expires":999999}}"#.utf8)
        let other = Data(#"{"openai":{"type":"api","key":"other"}}"#.utf8)

        XCTAssertEqual(OpenCodeGoAmbientCredentialLoader.apiKey(fromAuthData: api), "secret")
        XCTAssertNil(OpenCodeGoAmbientCredentialLoader.apiKey(fromAuthData: oauth))
        XCTAssertNil(OpenCodeGoAmbientCredentialLoader.apiKey(fromAuthData: other))
    }

    private func apiSnapshot(
        fiveHourUsed: Double,
        resetAfter: TimeInterval,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .openCodeGo,
            planName: "OpenCode Go",
            windows: [
                try UsageWindow(
                    kind: .fiveHour,
                    label: "5-hour",
                    usedPercent: fiveHourUsed,
                    resetsAt: now.addingTimeInterval(resetAfter),
                    resetDescription: nil),
                try UsageWindow(
                    kind: .weekly,
                    label: "Weekly",
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(86_400),
                    resetDescription: nil),
                try UsageWindow(
                    kind: .monthly,
                    label: "Monthly",
                    usedPercent: 30,
                    resetsAt: now.addingTimeInterval(2_592_000),
                    resetDescription: nil),
            ],
            fetchedAt: now)
    }
}
