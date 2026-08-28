import AppKit
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
