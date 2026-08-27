import Foundation

final class OpenCodeWorkspaceStore {
    private(set) var workspaceID: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, legacyURL: URL? = nil) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.workspaceID)
        let legacy = legacyURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GoUsage/workspace_id.txt")
        workspaceID = Self.valid(stored) ?? Self.readLegacy(legacy)
        if let workspaceID { defaults.set(workspaceID, forKey: Keys.workspaceID) }
    }

    var usageURL: URL {
        guard let workspaceID else { return URL(string: "https://opencode.ai/workspace")! }
        return URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")!
    }

    func save(_ candidate: String) {
        guard let value = Self.valid(candidate) else { return }
        workspaceID = value
        defaults.set(value, forKey: Keys.workspaceID)
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

    private enum Keys { static let workspaceID = "opencode.workspaceID" }
}
