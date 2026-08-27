import XCTest
@testable import AIUsage

final class OpenCodeWorkspaceStoreTests: XCTestCase {
    func testMigratesValidLegacyWorkspaceWithoutHardcodingIt() throws {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("workspace_id.txt")
        try Data("wrk_migrated123".utf8).write(to: legacy)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = OpenCodeWorkspaceStore(defaults: defaults, legacyURL: legacy)

        XCTAssertEqual(store.workspaceID, "wrk_migrated123")
        XCTAssertEqual(store.usageURL.absoluteString, "https://opencode.ai/workspace/wrk_migrated123/go")
    }

    func testUsesGenericWorkspacePageWhenNoIDExists() {
        let defaults = UserDefaults(suiteName: "AIUsageTests.\(UUID().uuidString)")!
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let store = OpenCodeWorkspaceStore(defaults: defaults, legacyURL: missing)

        XCTAssertNil(store.workspaceID)
        XCTAssertEqual(store.usageURL.absoluteString, "https://opencode.ai/workspace")
    }
}
