import Foundation

final class OpenCodeWorkspaceStore {
    private(set) var workspaceID: String?
    private let defaults: UserDefaults
    private let workspaceKey: String
    private let ignoreLegacyKey: String
    private let allowsLegacyMigration: Bool

    init(
        defaults: UserDefaults = .standard,
        legacyURL: URL? = nil,
        namespace: String = "default",
        allowsLegacyMigration: Bool = true)
    {
        self.defaults = defaults
        if namespace == "default" {
            self.workspaceKey = "opencode.workspaceID"
            self.ignoreLegacyKey = "opencode.ignoreLegacyWorkspaceID"
        } else {
            self.workspaceKey = "opencode.\(namespace).workspaceID"
            self.ignoreLegacyKey = "opencode.\(namespace).ignoreLegacyWorkspaceID"
        }
        self.allowsLegacyMigration = allowsLegacyMigration

        let stored = Self.valid(defaults.string(forKey: workspaceKey))
        let legacy = legacyURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GoUsage/workspace_id.txt")
        let migrated = allowsLegacyMigration && !defaults.bool(forKey: ignoreLegacyKey)
            ? Self.readLegacy(legacy)
            : nil

        workspaceID = stored ?? migrated
        if let workspaceID { defaults.set(workspaceID, forKey: workspaceKey) }
        if migrated != nil { defaults.set(true, forKey: ignoreLegacyKey) }
    }

    var usageURL: URL {
        guard let workspaceID else { return URL(string: "https://opencode.ai/workspace")! }
        return URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")!
    }

    func save(_ candidate: String) {
        guard let value = Self.valid(candidate) else { return }
        workspaceID = value
        defaults.set(value, forKey: workspaceKey)
        defaults.set(true, forKey: ignoreLegacyKey)
    }

    func clear() {
        workspaceID = nil
        defaults.removeObject(forKey: workspaceKey)
        defaults.set(true, forKey: ignoreLegacyKey)
    }

    private static func readLegacy(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return valid(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func valid(_ candidate: String?) -> String? {
        guard let candidate,
              candidate.range(of: #"^wrk_[A-Za-z0-9_\-]{3,128}$"#, options: .regularExpression) != nil
        else { return nil }
        return candidate
    }
}
