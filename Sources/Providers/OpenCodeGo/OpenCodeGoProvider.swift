import AppKit
import Foundation
import WebKit

/// GoUsage-compatible OpenCode Go fetcher. Each provider instance can receive a
/// distinct persistent WKWebsiteDataStore, allowing simultaneous accounts.
@MainActor
final class OpenCodeGoProvider: NSObject, UsageProvider {
    let id: ProviderID = .openCodeGo

    private let workspaceStore: OpenCodeWorkspaceStore
    private let webView: WKWebView
    private let hiddenWindow: NSWindow
    private var continuation: CheckedContinuation<ProviderSnapshot, Error>?
    private var activeGeneration = 0
    private var scrapeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var scrapeRetries = 0
    private(set) var lastObservedURL: URL?

    private var startURL: URL {
        workspaceStore.workspaceID == nil ? Self.discoveryURL : workspaceStore.usageURL
    }

    private static let discoveryURL = URL(string: "https://opencode.ai/console/")!

    init(
        workspaceStore: OpenCodeWorkspaceStore = OpenCodeWorkspaceStore(),
        dataStore: WKWebsiteDataStore = .default())
    {
        self.workspaceStore = workspaceStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            configuration: configuration)
        hiddenWindow = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1000, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        super.init()
        hiddenWindow.contentView = webView
        webView.navigationDelegate = self
    }

    func fetch() async throws -> ProviderSnapshot {
        guard continuation == nil else { throw OpenCodeGoError.navigation("refresh already in progress") }
        activeGeneration += 1
        scrapeRetries = 0
        let generation = activeGeneration
        defer { Task { @MainActor in self.lastObservedURL = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startTimeout(generation: generation)
            self.webView.load(URLRequest(
                url: self.startURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30))
        }
    }

    func cancelActiveFetch() {
        webView.stopLoading()
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation("fetch cancelled")))
    }

    private func startTimeout(generation: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled else { return }
            self?.complete(generation: generation, .failure(OpenCodeGoError.navigation("timed out")))
        }
    }

    private func scheduleScrape(generation: Int, delay: Duration = .seconds(2)) {
        scrapeTask?.cancel()
        scrapeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scrape(generation: generation)
        }
    }

    func scrape(generation: Int) {
        webView.evaluateJavaScript(Self.scrapeJS) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.activeGeneration == generation, self.continuation != nil else { return }
                if let error {
                    self.scrapeRetries += 1
                    if self.scrapeRetries <= 3 {
                        self.scheduleScrape(generation: generation, delay: .seconds(2))
                        return
                    }
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
                    return
                }
                guard let json = value as? String else {
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(OpenCodeGoError.invalidResponse))
                    return
                }
                if let redirect = Self.workspaceRedirect(from: json), redirect != self.webView.url {
                    self.webView.load(URLRequest(url: redirect, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                    return
                }
                do {
                    let result = try OpenCodeGoParser.parse(jsonText: json)
                    if let workspaceID = result.workspaceID { self.workspaceStore.save(workspaceID) }
                    self.complete(generation: generation, .success(result.snapshot))
                } catch {
                    self.lastObservedURL = self.webView.url
                    self.complete(generation: generation, .failure(error))
                }
            }
        }
    }

    private func complete(generation: Int, _ result: Result<ProviderSnapshot, Error>) {
        guard activeGeneration == generation, let continuation else { return }
        if case let .failure(error) = result,
           let openCodeError = error as? OpenCodeGoError,
           openCodeError == .invalidResponse,
           scrapeRetries < 3
        {
            scrapeRetries += 1
            scheduleScrape(generation: generation, delay: .seconds(2))
            return
        }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        scrapeTask?.cancel()
        scrapeTask = nil
        continuation.resume(with: result)
    }

    private static func workspaceRedirect(from json: String) -> URL? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlText = object["url"] as? String,
              let url = URL(string: urlText),
              url.host == "opencode.ai",
              url.path.range(of: #"^/workspace/wrk_[A-Za-z0-9_-]+(/go)?$"#, options: .regularExpression) != nil,
              let items = object["items"] as? [[String: Any]], items.isEmpty
        else { return nil }
        let path = url.path.hasSuffix("/go") ? url.path : url.path + "/go"
        return URL(string: "https://opencode.ai" + path)
    }

    private func isAllowedScraperURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        return url.host == "opencode.ai" || url.host == "auth.opencode.ai"
    }

    private static let scrapeJS = """
    (function(){
      var items = document.querySelectorAll('[data-slot="usage-item"]');
      var out = [];
      for (var i = 0; i < items.length; i++) {
        var el = items[i];
        var q = function(s){ var n = el.querySelector(s); return n && n.textContent ? n.textContent.trim() : ''; };
        out.push({ label: q('[data-slot="usage-label"]'), value: q('[data-slot="usage-value"]'), reset: q('[data-slot="reset-time"]') });
      }
      var promo = !!document.querySelector('[data-slot="subscribe-button"]');
      var other = !!document.querySelector('[data-slot="other-message"]');
      var cb = document.querySelector('form[data-slot="setting-row"] input[type="checkbox"]');
      var links = document.querySelectorAll('a[href*="/workspace/wrk_"]');
      var target = '';
      for (var j = 0; j < links.length; j++) {
        var href = links[j].href || '';
        if (href.indexOf('/go') >= 0) { target = href; break; }
      }
      if (!target) {
        var html = document.documentElement.innerHTML;
        var match = html.match(/(?:https:\\/\\/opencode\\.ai)?(\\/workspace\\/wrk_[A-Za-z0-9_-]+)(?:\\/go)?/);
        if (match) { target = 'https://opencode.ai' + match[1] + '/go'; }
      }
      if (!target) {
        var scripts = document.querySelectorAll('script');
        for (var k = 0; k < scripts.length && !target; k++) {
          var text = scripts[k].textContent || '';
          var m = text.match(/wrk_[A-Za-z0-9_-]{8,}/);
          if (m) { target = 'https://opencode.ai/workspace/' + m[0] + '/go'; }
        }
      }
      return JSON.stringify({
        url: target || location.href,
        items: out,
        promo: promo,
        other: other,
        useBalance: cb ? cb.checked : null
      });
    })()
    """
}

extension OpenCodeGoProvider: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
    {
        guard let url = navigationAction.request.url, isAllowedScraperURL(url) else {
            decisionHandler(.cancel)
            complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation("blocked navigation to an unexpected host")))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleScrape(generation: activeGeneration)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(generation: activeGeneration, .failure(OpenCodeGoError.navigation(error.localizedDescription)))
    }
}

/// Parser for OpenCode's lightweight Go usage endpoint. This endpoint is used
/// only as a recovery timing hint; the WebKit dashboard remains the source of
/// truth for values shown by AIUsage and for recovery notifications.
enum OpenCodeGoAPIUsageParser {
    static func parse(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenCodeGoAPIError.invalidResponse
        }

        let inputs: [(UsageWindowKind, String, APIWindow)] = [
            (.fiveHour, "5-hour", response.usage.rolling),
            (.weekly, "Weekly", response.usage.weekly),
            (.monthly, "Monthly", response.usage.monthly),
        ]
        let windows = try inputs.map { kind, label, item in
            guard item.percent.isFinite,
                  (0...100).contains(item.percent),
                  let reset = parseISO8601(item.resetsAt)
            else { throw OpenCodeGoAPIError.invalidResponse }
            return try UsageWindow(
                kind: kind,
                label: label,
                usedPercent: item.percent,
                resetsAt: reset,
                resetDescription: nil)
        }
        return ProviderSnapshot(
            provider: .openCodeGo,
            planName: "OpenCode Go",
            windows: windows,
            fetchedAt: now)
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
        let usage: Usage
    }

    private struct Usage: Decodable {
        let rolling: APIWindow
        let weekly: APIWindow
        let monthly: APIWindow
    }

    private struct APIWindow: Decodable {
        let percent: Double
        let resetsAt: String
    }
}

enum OpenCodeGoAPIError: LocalizedError, Equatable {
    case missingKey
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "OpenCode Go API key is missing."
        case .invalidResponse: "OpenCode Go recovery probe returned invalid usage data."
        case let .http(status): "OpenCode Go recovery probe returned HTTP \(status)."
        }
    }
}

@MainActor
enum OpenCodeGoAPIClient {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        let request = try makeRequest(apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeGoAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw OpenCodeGoAPIError.http(http.statusCode) }
        return try OpenCodeGoAPIUsageParser.parse(data: data)
    }

    static func makeRequest(apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenCodeGoAPIError.missingKey }
        var request = URLRequest(
            url: usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: RejectRedirectDelegate(),
            delegateQueue: nil)
    }
}

enum OpenCodeGoRecoveryPlanner {
    static let normalRecheckInterval: TimeInterval = 300
    static let minimumDelay: TimeInterval = 5
    static let resetGrace: TimeInterval = 2

    static func didRecover(previous: ProviderSnapshot?, current: ProviderSnapshot) -> Bool {
        guard let previous,
              previous.provider == .openCodeGo,
              current.provider == .openCodeGo else { return false }
        let old = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0.remainingPercent) })
        return current.windows.contains { window in
            guard let prior = old[window.id] else { return false }
            return prior < 100 && window.remainingPercent >= 100
        }
    }

    static func nextDelay(snapshot: ProviderSnapshot, now: Date) -> TimeInterval {
        let nextReset = snapshot.windows
            .filter { $0.remainingPercent < 100 }
            .compactMap(\.resetsAt)
            .min()
        guard let nextReset else { return normalRecheckInterval }
        let untilReset = nextReset.timeIntervalSince(now) + resetGrace
        return min(normalRecheckInterval, max(minimumDelay, untilReset))
    }
}

/// Optional best-effort monitor for faster OpenCode Go recovery notifications.
/// It never publishes API values. A lightweight API recovery transition only
/// triggers the normal WebKit refresh, which must independently confirm 100%.
@MainActor
final class OpenCodeGoRecoveryMonitor {
    typealias KeyLoader = (ProviderInstance) throws -> String?
    typealias ConfirmRefresh = (UUID) async -> Void

    private let session: URLSession
    private let keyLoader: KeyLoader
    private let confirmRefresh: ConfirmRefresh
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        session: URLSession = OpenCodeGoAPIClient.makeSession(),
        keyLoader: @escaping KeyLoader = { try ProviderInstanceCredentialStore.secret(for: $0) },
        confirmRefresh: @escaping ConfirmRefresh
    ) {
        self.session = session
        self.keyLoader = keyLoader
        self.confirmRefresh = confirmRefresh
    }

    func sync(instances: [ProviderInstance]) {
        let eligible = Dictionary(uniqueKeysWithValues: instances
            .filter { $0.provider == .openCodeGo }
            .map { ($0.id, $0) })

        for id in Set(tasks.keys).subtracting(eligible.keys) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        for (id, instance) in eligible where tasks[id] == nil {
            start(instance)
        }
    }

    func restart(_ instance: ProviderInstance) {
        tasks.removeValue(forKey: instance.id)?.cancel()
        guard instance.provider == .openCodeGo else { return }
        start(instance)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func start(_ instance: ProviderInstance) {
        tasks[instance.id] = Task { [weak self] in
            await self?.run(instance)
        }
    }

    private func run(_ instance: ProviderInstance) async {
        var previous: ProviderSnapshot?

        while !Task.isCancelled {
            do {
                guard let apiKey = try keyLoader(instance),
                      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }

                let current = try await OpenCodeGoAPIClient.fetch(apiKey: apiKey, session: session)
                if OpenCodeGoRecoveryPlanner.didRecover(previous: previous, current: current) {
                    await confirmRefresh(instance.id)
                }
                previous = current

                let delay = OpenCodeGoRecoveryPlanner.nextDelay(snapshot: current, now: Date())
                try await sleep(seconds: delay)
            } catch is CancellationError {
                return
            } catch let error as OpenCodeGoAPIError {
                if case let .http(status) = error, status == 401 || status == 403 || status == 404 {
                    return
                }
                try? await sleep(seconds: OpenCodeGoRecoveryPlanner.normalRecheckInterval)
            } catch {
                try? await sleep(seconds: OpenCodeGoRecoveryPlanner.normalRecheckInterval)
            }
        }
    }

    private func sleep(seconds: TimeInterval) async throws {
        let milliseconds = Int64(max(1, seconds * 1_000))
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
