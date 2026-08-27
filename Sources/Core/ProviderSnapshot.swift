import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case openCodeGo
    case qwen
    case codex
    case claude
    case antigravity
    case copilot
    case cursor
    case zai
    case kimi

    var id: String { rawValue }

    /// Providers exposed in the Add Provider UI. Keep this separate from
    /// `allCases` so future provider IDs / experimental integrations can exist
    /// in code without becoming user-selectable before their implementation is
    /// tested and ready.
    static let implemented: [ProviderID] = [
        .openCodeGo,
        .codex,
        .qwen,
        .claude,
        .antigravity,
        .copilot,
        .cursor,
        .zai,
        .kimi,
    ]

    var displayName: String {
        switch self {
        case .openCodeGo: "OpenCode Go"
        case .qwen: "Qwen Cloud"
        case .codex: "OpenAI Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub Copilot"
        case .cursor: "Cursor"
        case .zai: "Z.AI GLM"
        case .kimi: "Kimi Code"
        }
    }

    var shortName: String {
        switch self {
        case .openCodeGo: "GO"
        case .qwen: "Q"
        case .codex: "CX"
        case .claude: "CL"
        case .antigravity: "AG"
        case .copilot: "GH"
        case .cursor: "CU"
        case .zai: "ZA"
        case .kimi: "KM"
        }
    }

    /// Only these providers have credentials/session state owned by AIUsage.
    /// External-tool providers deliberately do not expose a misleading Sign
    /// out action that would imply AIUsage can log out Claude/Cursor/etc.
    var managesAuthentication: Bool {
        switch self {
        case .openCodeGo, .qwen, .copilot, .zai:
            true
        case .codex, .claude, .antigravity, .cursor, .kimi:
            false
        }
    }
}

struct ProviderSnapshot: Equatable, Sendable {
    let provider: ProviderID
    let planName: String?
    let windows: [UsageWindow]
    let fetchedAt: Date

    init(provider: ProviderID, planName: String?, windows: [UsageWindow], fetchedAt: Date) {
        self.provider = provider
        self.planName = planName
        self.windows = windows.sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.id < $1.id
        }
        self.fetchedAt = fetchedAt
    }

    var mostConstrainedRemaining: Double? {
        windows.map(\.remainingPercent).min()
    }
}

private extension UsageWindowKind {
    var sortOrder: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .monthly: 2
        }
    }
}
