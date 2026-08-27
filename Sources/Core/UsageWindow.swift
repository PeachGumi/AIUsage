import Foundation

enum UsageWindowKind: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
    case monthly
}

/// One independently metered provider quota.
///
/// `kind` describes the cadence, while `id` describes the actual quota lane.
/// They are intentionally separate: providers such as Antigravity and Cursor
/// can expose more than one five-hour/weekly/monthly quota at the same time.
struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: UsageWindowKind
    let label: String
    let compactLabel: String?
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?

    var remainingPercent: Double { 100 - usedPercent }

    init(
        id: String? = nil,
        kind: UsageWindowKind,
        label: String,
        compactLabel: String? = nil,
        usedPercent: Double,
        resetsAt: Date?,
        resetDescription: String?) throws
    {
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw UsageModelError.invalidPercentage
        }
        let resolvedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedID?.isEmpty != true else { throw UsageModelError.invalidIdentifier }

        self.id = resolvedID ?? kind.rawValue
        self.kind = kind
        self.label = label
        self.compactLabel = compactLabel
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

enum UsageModelError: LocalizedError {
    case invalidPercentage
    case invalidIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidPercentage:
            "Usage percentage must be finite and between 0 and 100."
        case .invalidIdentifier:
            "Usage window identifier must not be empty."
        }
    }
}
