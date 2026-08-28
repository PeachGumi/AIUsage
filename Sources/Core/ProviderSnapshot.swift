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

    /// Providers exposed in the Add Provider UI. Experimental providers are
    /// intentionally visible so users can validate them and contribute fixes;
    /// their status is surfaced explicitly in the UI and documentation.
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

    /// Only Codex and OpenCode Go have been validated against real maintainer
    /// accounts. Every other integration is contract/fixture-tested but remains
    /// experimental until real-account users confirm it against the provider's
    /// official usage display and contribute any required fixes.
    var isExperimental: Bool {
        switch self {
        case .openCodeGo, .codex:
            false
        case .qwen, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            true
        }
    }

    /// Only these providers have credentials/session state owned by AIUsage.
    /// Claude, Antigravity, Copilot, Cursor and Kimi reuse external clients'
    /// existing authentication read-only and therefore are never signed out by
    /// AIUsage.
    var managesAuthentication: Bool {
        switch self {
        case .openCodeGo, .qwen, .zai:
            true
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
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
