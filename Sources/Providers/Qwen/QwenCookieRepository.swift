import Foundation
import WebKit

/// Serves browser-equivalent Cookie headers per destination URL. Each provider
/// instance receives its own persistent WKWebsiteDataStore, so two Qwen cards
/// can remain signed into different accounts simultaneously.
@MainActor
final class QwenCookieRepository {
    let dataStore: WKWebsiteDataStore
    private let defaults: UserDefaults
    private let legacyURL: URL
    private let ignoreLegacyKey: String
    private let allowsLegacyMigration: Bool

    init(
        dataStore: WKWebsiteDataStore = .default(),
        defaults: UserDefaults = .standard,
        legacyURL: URL? = nil,
        namespace: String = "default",
        allowsLegacyMigration: Bool = true)
    {
        self.dataStore = dataStore
        self.defaults = defaults
        self.legacyURL = legacyURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenUsage/saved_cookies.txt")
        self.ignoreLegacyKey = namespace == "default"
            ? "qwen.ignoreLegacyCookie"
            : "qwen.\(namespace).ignoreLegacyCookie"
        self.allowsLegacyMigration = allowsLegacyMigration
    }

    func header(for url: URL) async throws -> String {
        let cookies = await cookies(matching: url)
        let header = cookies
            .sorted { ($0.name, $0.path) < ($1.name, $1.path) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if !header.isEmpty { return header }

        guard allowsLegacyMigration,
              Self.isLegacyCompatible(url),
              !defaults.bool(forKey: ignoreLegacyKey),
              let legacy = try? String(contentsOf: legacyURL, encoding: .utf8),
              Self.isValidHeaderShape(legacy)
        else { throw QwenUsageError.notLoggedIn }
        return legacy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markLoginSucceeded() {
        defaults.set(true, forKey: ignoreLegacyKey)
    }

    func logout() async {
        defaults.set(true, forKey: ignoreLegacyKey)
        for cookie in await allCookies() where Self.isQwenFamily(cookie.domain) {
            await delete(cookie)
        }
    }

    private func cookies(matching url: URL) async -> [HTTPCookie] {
        await allCookies().filter { Self.browserWouldSend(cookie: $0, to: url) }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    nonisolated static func browserWouldSend(cookie: HTTPCookie, to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard Self.domainMatches(cookieDomain: cookie.domain.lowercased(), host: host) else { return false }
        guard Self.pathMatches(cookiePath: cookie.path, requestPath: url.path) else { return false }
        if let expires = cookie.expiresDate { return expires > Date() }
        return true
    }

    nonisolated static func domainMatches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return domain == host || host.hasSuffix("." + domain)
    }

    nonisolated static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath == "/" || requestPath == cookiePath || cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary < requestPath.endIndex && requestPath[boundary] == "/"
    }

    nonisolated static func isQwenFamily(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "qwencloud.com" || normalized.hasSuffix(".qwencloud.com") ||
            normalized == "qianwenai.com" || normalized.hasSuffix(".qianwenai.com")
    }

    nonisolated static func isLegacyCompatible(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "home.qwencloud.com"
    }

    nonisolated static func isValidHeaderShape(_ header: String) -> Bool {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        return trimmed.split(separator: ";").allSatisfy { pair in
            let part = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = part.firstIndex(of: "="), equals != part.startIndex else { return false }
            let name = part[..<equals]
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
    }
}
