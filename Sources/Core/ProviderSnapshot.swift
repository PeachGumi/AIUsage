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

    /// Integrations implemented by AIUsage and eligible for the Add Provider UI.
    /// SettingsStore may further constrain this catalog for providers that do not
    /// yet have a safe multi-account isolation mechanism (currently Antigravity).
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
    /// accounts. Other integrations remain explicitly Experimental until their
    /// fixture contracts are confirmed against real provider dashboards.
    var isExperimental: Bool {
        switch self {
        case .openCodeGo, .codex:
            false
        case .qwen, .claude, .antigravity, .copilot, .cursor, .zai, .kimi:
            true
        }
    }

    /// Providers whose primary sign-in/sign-out lifecycle is owned by AIUsage.
    /// Other integrations may still accept an AIUsage-owned per-card credential,
    /// but their ambient/default login remains owned by the external client.
    var managesAuthentication: Bool {
        switch self {
        case .openCodeGo, .qwen, .zai:
            true
        case .codex, .claude, .antigravity, .copilot, .cursor, .kimi:
            false
        }
    }
}

/// One dashboard/account slot. ProviderID identifies the integration type;
/// ProviderInstance.id identifies one independently managed account/card.
/// Multiple instances of the same provider are intentionally valid where the
/// integration has an isolation mechanism.
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
        guard let accountLabel else { return provider.displayName }
        return "\(provider.displayName) · \(accountLabel)"
    }

    /// Historical name retained because these IDs originated as migration IDs.
    /// In the current model this means the stable default slot: the one account
    /// allowed to reuse an ambient external-client login/profile.
    var isLegacyMigratedInstance: Bool {
        id == Self.legacyID(for: provider)
    }

    func withAccountLabel(_ value: String?) -> ProviderInstance {
        ProviderInstance(id: id, provider: provider, accountLabel: value)
    }

    /// Stable default-slot IDs. The values deliberately match the migration IDs
    /// from the old one-card-per-provider representation, which preserves existing
    /// WebKit/default-client state while also giving fresh installs one recoverable
    /// ambient-auth slot per provider. Additional accounts always use random UUIDs.
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
            preconditionFailure("Internal legacy provider UUID is invalid")
        }
        return id
    }

    private static func cleanedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
