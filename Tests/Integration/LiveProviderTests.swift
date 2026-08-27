import XCTest
@testable import AIUsage

@MainActor
final class LiveProviderTests: XCTestCase {
    private let marker = "/tmp/aiusage-live-tests-enabled"

    func testCodexLiveAccount() async throws {
        try requireOptIn()
        let snapshot = try await CodexProvider().fetch()
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
        report(provider: "Codex", snapshot: snapshot)
    }

    func testQwenLiveAccount() async throws {
        try requireOptIn()
        do {
            let snapshot = try await QwenProvider().fetch()
            XCTAssertEqual(snapshot.provider, .qwen)
            XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
            report(provider: "Qwen", snapshot: snapshot)
        } catch QwenUsageError.noActiveSubscription {
            print("LIVE Qwen: authenticated, API reports no active Token Plan usage")
        }
    }

    func testOpenCodeGoLiveAccount() async throws {
        try requireOptIn()
        let provider = OpenCodeGoProvider()
        do {
            let snapshot = try await provider.fetch()
            XCTAssertEqual(snapshot.provider, .openCodeGo)
            XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly, .monthly])
            report(provider: "OpenCode Go", snapshot: snapshot)
        } catch is CancellationError {
            XCTFail("OpenCode fetch was cancelled — likely a navigation to a non-allowlisted URL (sign-in redirect?).")
        }
    }

    private func requireOptIn() throws {
        guard FileManager.default.fileExists(atPath: marker) else {
            throw XCTSkip("Create \(marker) to enable account-backed tests.")
        }
    }

    /// Keep real usage values out of logs: report only freshness and window
    /// structure, mirroring the project's no-usage-logging posture.
    private func report(provider: String, snapshot: ProviderSnapshot) {
        let windows = snapshot.windows.map { "\($0.label): ok" }.joined(separator: ", ")
        let age = Int(-snapshot.fetchedAt.timeIntervalSinceNow)
        print("LIVE \(provider): fetched \(windows) (\(age)s ago)")
    }
}
