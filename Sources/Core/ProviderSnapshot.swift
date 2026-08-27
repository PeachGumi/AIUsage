import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case openCodeGo
    case qwen
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCodeGo: "OpenCode Go"
        case .qwen: "Qwen Cloud"
        case .codex: "OpenAI Codex"
        }
    }

    var shortName: String {
        switch self {
        case .openCodeGo: "GO"
        case .qwen: "Q"
        case .codex: "CX"
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
        self.windows = windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
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
