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

        // Prefer semantic labels so a harmless DOM reorder cannot swap quota
        // meanings. Positional fallback is reserved for legacy variants that
        // expose no recognizable labels at all. Partial/duplicate recognition
        // is ambiguous and fails closed rather than showing a wrong quota.
        let items = try semanticallyMappedItems(response.items) ?? positionalItems(response.items)
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

    private static func semanticallyMappedItems(_ items: [Item]) throws -> [(UsageWindowKind, Item)]? {
        let recognized = items.compactMap { item -> (UsageWindowKind, Item)? in
            guard let kind = kind(from: item.label) else { return nil }
            return (kind, item)
        }
        if recognized.isEmpty { return nil }

        let kinds = recognized.map(\.0)
        guard Set(kinds).count == kinds.count,
              UsageWindowKind.allCases.allSatisfy(kinds.contains)
        else { throw OpenCodeGoError.invalidResponse }
        return recognized
    }

    private static func positionalItems(_ items: [Item]) -> [(UsageWindowKind, Item)] {
        Array(zip([.fiveHour, .weekly, .monthly], items.prefix(3)))
    }

    private static func kind(from label: String?) -> UsageWindowKind? {
        guard let label = label?.lowercased() else { return nil }
        if (label.contains("hour") && (label.contains("5") || label.contains("five")))
            || label.contains("rolling")
            || (label.contains("時間") && label.contains("5")) { return .fiveHour }
        if label.contains("week") || label.contains("週") { return .weekly }
        if label.contains("month") || label.contains("月") { return .monthly }
        return nil
    }

    private static func parsePercent(_ text: String?) throws -> Double {
        guard let text else { throw OpenCodeGoError.invalidResponse }
        let normalized = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value.isFinite, value >= 0 else {
            throw OpenCodeGoError.invalidResponse
        }
        return min(value, 100)
    }

    private static func pageError(_ response: Response) -> OpenCodeGoError {
        if response.promo == true { return .notSubscribed }
        if response.other == true { return .otherWorkspaceMember }
        if response.url.contains("/auth") ||
            response.url.contains("auth.opencode.ai") ||
            response.url.contains("/console/login")
        {
            return .notLoggedIn
        }
        return .invalidResponse
    }

    private static func workspaceID(_ urlText: String) -> String? {
        guard let url = URL(string: urlText) else { return nil }
        for marker in ["console", "workspace"] {
            guard let index = url.pathComponents.firstIndex(of: marker),
                  url.pathComponents.indices.contains(index + 1)
            else { continue }
            let candidate = url.pathComponents[index + 1]
            if candidate.hasPrefix("wrk_") { return candidate }
        }
        return nil
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

enum OpenCodeGoConsoleStatusParser {
    static func parse(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenCodeGoError.invalidResponse
        }
        guard let access = response.access else { throw OpenCodeGoError.notSubscribed }

        let inputs: [(UsageWindowKind, String, Meter, String?)] = [
            (.fiveHour, "Rolling usage", access.meters.fiveHour, access.meters.fiveHour.resetsAt),
            (.weekly, "Weekly usage", access.meters.week, access.meters.week.resetsAt),
            (.monthly, "Monthly usage", access.meters.month, access.endsAt),
        ]
        let windows = try inputs.map { kind, label, meter, resetText in
            let usedPercent = try percent(used: meter.usedMicroCents, limit: meter.limitMicroCents)
            let resetDate = resetText.flatMap(parseISO8601)
            return try UsageWindow(
                kind: kind,
                label: label,
                usedPercent: usedPercent,
                resetsAt: resetDate,
                // Let the UI format valid dates in the Mac's local time zone.
                resetDescription: resetDate == nil ? resetText : nil)
        }
        let planName = response.useBalance.map {
            "OpenCode Go · balance fallback \($0 ? "on" : "off")"
        } ?? "OpenCode Go"
        return ProviderSnapshot(
            provider: .openCodeGo,
            planName: planName,
            windows: windows,
            fetchedAt: now)
    }

    private static func percent(used: String, limit: String) throws -> Double {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let usedValue = Decimal(string: used, locale: locale),
              let limitValue = Decimal(string: limit, locale: locale),
              usedValue >= 0,
              limitValue > 0
        else { throw OpenCodeGoError.invalidResponse }
        let value = NSDecimalNumber(decimal: usedValue / limitValue * 100).doubleValue
        guard value.isFinite, value >= 0 else { throw OpenCodeGoError.invalidResponse }
        return min(value, 100)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct Response: Decodable {
        let access: Access?
        let useBalance: Bool?
    }

    private struct Access: Decodable {
        let endsAt: String
        let meters: Meters
    }

    private struct Meters: Decodable {
        let fiveHour: Meter
        let week: Meter
        let month: Meter
    }

    private struct Meter: Decodable {
        let usedMicroCents: String
        let limitMicroCents: String
        let resetsAt: String?
    }
}

enum OpenCodeGoError: LocalizedError, Equatable, ProviderAuthenticationError {
    case notLoggedIn
    case notSubscribed
    case otherWorkspaceMember
    case invalidResponse
    case navigation(String)

    var requiresAuthentication: Bool {
        if case .notLoggedIn = self { return true }
        return false
    }

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
