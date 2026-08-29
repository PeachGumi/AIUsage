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

    var isExperimental: Bool {
        self != .openCodeGo && self != .codex
    }

    var supportsMultipleAccounts: Bool {
        self != .antigravity
    }

    var managesAuthentication: Bool {
        switch self {
        case .openCodeGo, .qwen, .zai: true
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi: false
        }
    }
}

struct ProviderInstance: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let provider: ProviderID
    var accountLabel: String?

    init(id: UUID = UUID(), provider: ProviderID, accountLabel: String? = nil) {
        self.id = id
        self.provider = provider
        self.accountLabel = Self.cleanedLabel(accountLabel)
    }

    var title: String {
        accountLabel.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
    }

    /// Stable default slot used by fresh installs and legacy migration. Only this
    /// slot may reuse ambient credentials owned by an external client.
    var isLegacyMigratedInstance: Bool {
        id == Self.legacyID(for: provider)
    }

    func withAccountLabel(_ value: String?) -> ProviderInstance {
        ProviderInstance(id: id, provider: provider, accountLabel: value)
    }

    static func legacyID(for provider: ProviderID) -> UUID {
        let suffix: String = switch provider {
        case .openCodeGo: "000000000001"
        case .qwen: "000000000002"
        case .codex: "000000000003"
        case .claude: "000000000004"
        case .antigravity: "000000000005"
        case .copilot: "000000000006"
        case .cursor: "000000000007"
        case .zai: "000000000008"
        case .kimi: "000000000009"
        }
        guard let id = UUID(uuidString: "A1A6E000-0000-4000-8000-\(suffix)") else {
            preconditionFailure("Internal provider UUID is invalid")
        }
        return id
    }

    private static func cleanedLabel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
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
            ($0.kind.sortOrder, $0.id) < ($1.kind.sortOrder, $1.id)
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
