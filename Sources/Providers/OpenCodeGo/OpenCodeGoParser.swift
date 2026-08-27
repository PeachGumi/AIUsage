import Foundation

struct OpenCodeGoResult: Equatable, Sendable {
    let snapshot: ProviderSnapshot
    let workspaceID: String?
}

enum OpenCodeGoParser {
    static func parse(jsonText: String, now: Date = Date()) throws -> OpenCodeGoResult {
        guard let data = jsonText.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { throw OpenCodeGoError.invalidResponse }
        guard response.items.count >= 3 else { throw pageError(response) }

        // Prefer the semantic labels exposed by the page so a harmless DOM
        // reorder cannot swap 5-hour/weekly/monthly usage. Fall back to the
        // historical first-three ordering only when the labels are incomplete
        // or unknown, preserving compatibility with older page variants.
        let items = semanticallyMappedItems(response.items) ?? positionalItems(response.items)
        let windows = try items.map { kind, item in
            try UsageWindow(
                kind: kind,
                label: item.label?.nonEmptyText ?? MenuBarPresentation.label(kind),
                usedPercent: parsePercent(item.value),
                resetsAt: nil,
                resetDescription: item.reset?.nonEmptyText)
        }
        let snapshot = ProviderSnapshot(
            provider: .openCodeGo,
            planName: planName(useBalance: response.useBalance),
            windows: windows,
            fetchedAt: now)
        return OpenCodeGoResult(snapshot: snapshot, workspaceID: workspaceID(response.url))
    }

    private static func semanticallyMappedItems(_ items: [Item]) -> [(UsageWindowKind, Item)]? {
        var mapped: [(UsageWindowKind, Item)] = []
        for item in items {
            guard let kind = kind(from: item.label) else { continue }
            guard !mapped.contains(where: { $0.0 == kind }) else { return nil }
            mapped.append((kind, item))
        }
        guard UsageWindowKind.allCases.allSatisfy({ kind in mapped.contains(where: { $0.0 == kind }) }) else {
            return nil
        }
        return mapped
    }

    private static func positionalItems(_ items: [Item]) -> [(UsageWindowKind, Item)] {
        Array(zip([.fiveHour, .weekly, .monthly], items.prefix(3)))
    }

    private static func kind(from label: String?) -> UsageWindowKind? {
        guard let label = label?.lowercased() else { return nil }
        if label.contains("hour") && (label.contains("5") || label.contains("five")) { return .fiveHour }
        if label.contains("week") { return .weekly }
        if label.contains("month") { return .monthly }
        return nil
    }

    private static func parsePercent(_ text: String?) throws -> Double {
        guard let text else { throw OpenCodeGoError.invalidResponse }
        let normalized = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value.isFinite, (0...100).contains(value) else {
            throw OpenCodeGoError.invalidResponse
        }
        return value
    }

    private static func pageError(_ response: Response) -> OpenCodeGoError {
        if response.promo == true { return .notSubscribed }
        if response.other == true { return .otherWorkspaceMember }
        if response.url.contains("/auth") || response.url.contains("auth.opencode.ai") { return .notLoggedIn }
        return .invalidResponse
    }

    private static func workspaceID(_ urlText: String) -> String? {
        guard let url = URL(string: urlText),
              let index = url.pathComponents.firstIndex(of: "workspace"),
              url.pathComponents.indices.contains(index + 1)
        else { return nil }
        let candidate = url.pathComponents[index + 1]
        return candidate.hasPrefix("wrk_") ? candidate : nil
    }

    private static func planName(useBalance: Bool?) -> String {
        guard let useBalance else { return "OpenCode Go" }
        return "OpenCode Go · balance fallback \(useBalance ? "on" : "off")"
    }

    private struct Response: Decodable {
        let url: String
        let items: [Item]
        let promo: Bool?
        let other: Bool?
        let useBalance: Bool?
    }

    private struct Item: Decodable {
        let label: String?
        let value: String?
        let reset: String?
    }
}

enum OpenCodeGoError: LocalizedError, Equatable {
    case notLoggedIn
    case notSubscribed
    case otherWorkspaceMember
    case invalidResponse
    case navigation(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "OpenCode login is required."
        case .notSubscribed: "This workspace is not subscribed to OpenCode Go."
        case .otherWorkspaceMember: "OpenCode Go is subscribed by another workspace member."
        case .invalidResponse: "OpenCode returned invalid usage data. The page structure may have changed."
        case let .navigation(message): "OpenCode page failed to load: \(message)"
        }
    }
}

private extension String {
    var nonEmptyText: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
