import XCTest
import WebKit
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

    func testUsesJapaneseLabelsWhenUpstreamReordersUsageCards() throws {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"月間利用量","value":"67.9%"},{"label":"5時間利用量","value":"102.5%"},{"label":"週間利用量","value":"42.3%"}],"promo":false,"other":false,"useBalance":false}"#

        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [100, 42.3, 67.9])
    }

    func testParsesCurrentConsoleUsageLabels() throws {
        let json = #"{"url":"https://opencode.ai/console/wrk_example/go","items":[{"label":"Monthly usage","value":"33%"},{"label":"Rolling usage","value":"11%"},{"label":"Weekly usage","value":"22%"}],"promo":false,"other":false,"useBalance":null}"#

        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.workspaceID, "wrk_example")
        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [11, 22, 33])
    }

    func testClassifiesCurrentConsoleLoginAsAuthenticationFailure() {
        let json = #"{"url":"https://opencode.ai/console/login","items":[],"promo":false,"other":false,"useBalance":null}"#

        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: json)) { error in
            XCTAssertEqual(error as? OpenCodeGoError, .notLoggedIn)
        }
    }

    @MainActor
    func testScrapesCurrentConsoleGoUsageCards() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let html = #"""
        <a href="/console/wrk_example/go">Go</a>
        <section aria-label="Go usage limits">
          <div><p><span>Rolling usage</span><span>11%</span></p><span title="2026-09-20 01:00">Resets in 2h</span></div>
          <div><p><span>Weekly usage</span><span>22%</span></p><span title="2026-09-26 01:00">Resets in 6d</span></div>
          <div><p><span>Monthly usage</span><span>33%</span></p><span title="2026-10-01 01:00">Resets in 11d</span></div>
        </section>
        """#
        webView.loadHTMLString(
            html,
            baseURL: URL(string: "https://opencode.ai/console/wrk_example/go")!)

        var loaded = false
        for _ in 0..<100 {
            if let count = try? await webView.evaluateJavaScript(
                "document.querySelectorAll('[aria-label=\"Go usage limits\"]').length") as? Int,
               count == 1
            {
                loaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(loaded)

        let evaluated = try await webView.evaluateJavaScript(OpenCodeGoProvider.scrapeJS)
        let json = try XCTUnwrap(evaluated as? String)
        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.workspaceID, "wrk_example")
        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [11, 22, 33])
        XCTAssertEqual(
            result.snapshot.windows.map(\.resetDescription),
            ["2026-09-20 01:00", "2026-09-26 01:00", "2026-10-01 01:00"])
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

    func testClampsOveragePercentagesAtFullyUsed() throws {
        let json = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"label":"5時間利用量","value":"102.5%"},{"label":"週間利用量","value":"42.3%"},{"label":"月間利用量","value":"67.9%"}],"promo":false,"other":false,"useBalance":false}"#

        let result = try OpenCodeGoParser.parse(jsonText: json)

        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [100, 42.3, 67.9])
        let remaining = result.snapshot.windows.map(\.remainingPercent)
        XCTAssertEqual(remaining[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(remaining[1], 57.7, accuracy: 0.000_001)
        XCTAssertEqual(remaining[2], 32.1, accuracy: 0.000_001)
    }

    func testRejectsMalformedAndNegativePercentages() {
        let malformed = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"oops"},{"value":"32.1%"}]}"#
        let negative = #"{"url":"https://opencode.ai/workspace/wrk_example/go","items":[{"value":"0.2%"},{"value":"0.1%"},{"value":"-1%"}]}"#

        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: malformed))
        XCTAssertThrowsError(try OpenCodeGoParser.parse(jsonText: negative))
    }

    func testConsoleStatusParserBuildsUsageSnapshot() throws {
        let data = Data(#"{"access":{"startsAt":"2026-09-01T00:00:00Z","endsAt":"2026-10-01T00:00:00Z","meters":{"fiveHour":{"usedMicroCents":"125000","limitMicroCents":"1000000","startsAt":"2026-09-19T20:00:00Z","resetsAt":"2026-09-20T01:00:00Z"},"week":{"usedMicroCents":"250000","limitMicroCents":"1000000","startsAt":"2026-09-14T00:00:00Z","resetsAt":"2026-09-21T00:00:00Z"},"month":{"usedMicroCents":"375000","limitMicroCents":"1000000"}}},"useBalance":true}"#.utf8)
        let now = Date(timeIntervalSince1970: 123)

        let snapshot = try OpenCodeGoConsoleStatusParser.parse(data: data, now: now)

        XCTAssertEqual(snapshot.provider, .openCodeGo)
        XCTAssertEqual(snapshot.planName, "OpenCode Go · balance fallback on")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12.5, 25, 37.5])
        XCTAssertEqual(snapshot.windows[0].resetDescription, "2026-09-20T01:00:00Z")
        XCTAssertEqual(snapshot.windows[1].resetDescription, "2026-09-21T00:00:00Z")
        XCTAssertEqual(snapshot.windows[2].resetDescription, "2026-10-01T00:00:00Z")
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testAPIUsageParserProvidesUsedPercentAndResetDates() throws {
        let data = Data(#"{"usage":{"rolling":{"status":"ok","percent":0.1,"resetsAt":"2026-09-01T00:00:30.000Z"},"weekly":{"status":"ok","percent":20,"resetsAt":"2026-09-03T00:00:00Z"},"monthly":{"status":"ok","percent":30,"resetsAt":"2026-10-01T00:00:00Z"}}}"#.utf8)
        let now = Date(timeIntervalSince1970: 123)

        let snapshot = try OpenCodeGoAPIUsageParser.parse(data: data, now: now)

        XCTAssertEqual(snapshot.provider, .openCodeGo)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0.1, 20, 30])
        let remaining = try XCTUnwrap(snapshot.windows.first?.remainingPercent)
        XCTAssertEqual(remaining, 99.9, accuracy: 0.000_001)
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

    func testConsoleOrganizationsResponseFindsWorkspaceID() throws {
        let data = Data(#"[{"id":"invalid","name":"Ignore"},{"id":"wrk_example","name":"Default"}]"#.utf8)

        XCTAssertEqual(try OpenCodeGoConsoleClient.parseWorkspaceID(data: data), "wrk_example")
    }

    @MainActor
    func testConsoleClientDiscoversWorkspaceAndFetchesStatus() async throws {
        let suite = "OpenCodeGoConsoleClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OpenCodeWorkspaceStore(defaults: defaults, allowsLegacyMigration: false)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "opencode.ai",
            .path: "/",
            .name: "__Host-console_session",
            .value: "fixture-session",
            .secure: "TRUE",
        ]))
        var requestedPaths: [String] = []
        let client = OpenCodeGoConsoleClient(
            workspaceStore: store,
            cookieLoader: { [cookie] },
            requestLoader: { request in
                requestedPaths.append(request.url?.path ?? "")
                let data: Data
                switch request.url?.path {
                case "/console/api/orgs":
                    data = Data(#"[{"id":"wrk_example","name":"Default"}]"#.utf8)
                case "/console/api/go/status":
                    data = Data(#"{"access":{"endsAt":"2026-10-01T00:00:00Z","meters":{"fiveHour":{"usedMicroCents":"100000","limitMicroCents":"1000000","resetsAt":null},"week":{"usedMicroCents":"200000","limitMicroCents":"1000000","resetsAt":"2026-09-21T00:00:00Z"},"month":{"usedMicroCents":"300000","limitMicroCents":"1000000","resetsAt":null}}},"useBalance":false}"#.utf8)
                default:
                    throw URLError(.unsupportedURL)
                }
                return (data, HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
            })

        let snapshot = try await client.fetch()

        XCTAssertEqual(requestedPaths, ["/console/api/orgs", "/console/api/go/status"])
        XCTAssertEqual(store.workspaceID, "wrk_example")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [10, 20, 30])
    }

    @MainActor
    func testConsoleStatusRequestIsPinnedToWorkspaceAPI() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "opencode.ai",
            .path: "/",
            .name: "__Host-console_session",
            .value: "fixture-session",
            .secure: "TRUE",
        ]))

        let request = try OpenCodeGoConsoleClient.makeStatusRequest(
            workspaceID: "wrk_example",
            cookies: [cookie])

        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/console/api/go/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-org-id"), "wrk_example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Host-console_session=fixture-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
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

@MainActor
final class OpenCodeGoNavigationTests: XCTestCase {
    func testConsoleSnapshotLoadsWithoutWaitingForDashboardDOM() async throws {
        let suite = "AIUsageNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = NavigationStubWebView(frame: .zero, configuration: configuration)
        let expected = try OpenCodeGoConsoleStatusParser.parse(data: Data(#"{"access":{"endsAt":"2026-10-01T00:00:00Z","meters":{"fiveHour":{"usedMicroCents":"100000","limitMicroCents":"1000000","resetsAt":null},"week":{"usedMicroCents":"200000","limitMicroCents":"1000000","resetsAt":"2026-09-21T00:00:00Z"},"month":{"usedMicroCents":"300000","limitMicroCents":"1000000","resetsAt":null}}},"useBalance":false}"#.utf8))
        let provider = OpenCodeGoProvider(
            workspaceStore: OpenCodeWorkspaceStore(defaults: defaults, allowsLegacyMigration: false),
            dataStore: .nonPersistent(),
            injectedWebView: webView,
            consoleSnapshotLoader: { expected })

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot, expected)
        XCTAssertTrue(webView.navigations.isEmpty)
    }

    func testRetriesConsoleAfterDashboardLoadHydratesWebSession() async throws {
        let suite = "AIUsageNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = NavigationStubWebView(frame: .zero, configuration: configuration)
        let expected = try OpenCodeGoConsoleStatusParser.parse(data: Data(#"{"access":{"endsAt":"2026-10-01T00:00:00Z","meters":{"fiveHour":{"usedMicroCents":"100000","limitMicroCents":"1000000","resetsAt":null},"week":{"usedMicroCents":"200000","limitMicroCents":"1000000","resetsAt":"2026-09-21T00:00:00Z"},"month":{"usedMicroCents":"300000","limitMicroCents":"1000000","resetsAt":null}}},"useBalance":false}"#.utf8))
        var attempts = 0
        let provider = OpenCodeGoProvider(
            workspaceStore: OpenCodeWorkspaceStore(defaults: defaults, allowsLegacyMigration: false),
            dataStore: .nonPersistent(),
            injectedWebView: webView,
            consoleSnapshotLoader: {
                attempts += 1
                if attempts == 1 { throw OpenCodeGoError.notLoggedIn }
                return expected
            })
        defer { provider.cancelActiveFetch() }

        let task = Task { try await provider.fetch() }
        for _ in 0..<400 where webView.navigations.isEmpty { await Task.yield() }
        _ = try XCTUnwrap(webView.navigations.first)
        provider.scrape(generation: 1)

        let snapshot = try await task.value
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(attempts, 2)
    }

    func testThirdPartySubframeIsCancelledWithoutRejectingMainNavigation() {
        XCTAssertEqual(
            OpenCodeGoProvider.navigationDecision(
                for: URL(string: "https://js.stripe.com/v3/controller.html")!,
                isMainFrame: false),
            .cancelSubframe)
        XCTAssertEqual(
            OpenCodeGoProvider.navigationDecision(
                for: URL(string: "https://js.stripe.com/v3/controller.html")!,
                isMainFrame: true),
            .rejectMainFrame)
        XCTAssertEqual(
            OpenCodeGoProvider.navigationDecision(
                for: URL(string: "https://opencode.ai/console/wrk_example/go")!,
                isMainFrame: true),
            .allow)
    }

    func testOldNavigationFailuresCannotCompleteReplacementFetch() async throws {
        for provisional in [true, false] {
            let suite = "AIUsageNavigationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = NavigationStubWebView(frame: .zero, configuration: configuration)
            let provider = OpenCodeGoProvider(
                workspaceStore: OpenCodeWorkspaceStore(defaults: defaults, allowsLegacyMigration: false),
                dataStore: .nonPersistent(),
                injectedWebView: webView)
            defer { provider.cancelActiveFetch() }

            let first = Task { try? await provider.fetch() }
            for _ in 0..<400 where webView.navigations.isEmpty { await Task.yield() }
            let old = try XCTUnwrap(webView.navigations.first)
            provider.cancelActiveFetch()
            _ = await first.value

            var replacementFinished = false
            let second = Task { () -> String in
                defer { replacementFinished = true }
                do {
                    _ = try await provider.fetch()
                    return "unexpected success"
                } catch {
                    return error.localizedDescription
                }
            }
            for _ in 0..<400 where webView.navigations.count < 2 { await Task.yield() }
            XCTAssertEqual(webView.navigations.count, 2)
            let current = try XCTUnwrap(webView.navigations.last)
            if provisional {
                provider.webView(webView, didFailProvisionalNavigation: old, withError: URLError(.cancelled))
            } else {
                provider.webView(webView, didFail: old, withError: URLError(.cancelled))
            }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertFalse(replacementFinished, "An old navigation failure completed the replacement fetch")

            provider.webView(webView, didFail: current, withError: URLError(.timedOut))
            let result = await second.value
            XCTAssertEqual(result, OpenCodeGoError.navigation(URLError(.timedOut).localizedDescription).localizedDescription)
        }
    }
}

@MainActor
private final class NavigationStubWebView: WKWebView {
    var navigations: [WKNavigation] = []
    // WKNavigation() lacks WebKit's backing object and crashes on deallocation.
    // Local HTML produces real navigation identities without provider callbacks or network access.
    private lazy var navigationSource: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    override func load(_ request: URLRequest) -> WKNavigation? {
        guard let navigation = navigationSource.loadHTMLString("<html></html>", baseURL: nil) else { return nil }
        navigations.append(navigation)
        return navigation
    }

    override func stopLoading() { navigationSource.stopLoading() }
}
