import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: UsageCoordinator
    private let settings: SettingsStore
    private var dashboardWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: UsageCoordinator, settings: SettingsStore, actions: AppActions) {
        self.coordinator = coordinator
        self.settings = settings
        self.actions = actions
        super.init()
        configureButton()
        observeChanges()
        render()
    }

    private let actions: AppActions

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.setAccessibilityRole(.button)
        button.addObserver(self, forKeyPath: "effectiveAppearance", context: nil)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?)
    {
        if keyPath == "effectiveAppearance" {
            Task { @MainActor [weak self] in self?.render() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func observeChanges() {
        Publishers.CombineLatest3(settings.$selectedProvider, settings.$metric, coordinator.$snapshots)
            .combineLatest(coordinator.$errors)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    /// Left click cycles the displayed provider (users switch often);
    /// right click (or command-click) opens the dashboard window.
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { cycleProvider(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.command) {
            showDashboard(actions: actions)
        } else {
            cycleProvider()
        }
    }

    private func cycleProvider() {
        // Cycle through the user's dashboard order rather than the raw enum.
        let order = settings.providerOrder
        guard let index = order.firstIndex(of: settings.selectedProvider) else { return }
        settings.selectedProvider = order[(index + 1) % order.count]
    }

    private func showDashboard(actions: AppActions) {
        if let window = dashboardWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let dashboard = DashboardView(coordinator: coordinator, settings: settings, actions: actions)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "AI Usage"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: dashboard)
        window.center()
        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let provider = settings.selectedProvider
        let snapshot = coordinator.snapshots[provider]
        let hasError = coordinator.errors[provider] != nil
        let title = displayTitle(provider: provider, snapshot: snapshot, hasError: hasError)
        let image = renderImage(title: title, snapshot: snapshot, provider: provider, hasError: hasError)
        statusItem.length = image.size.width + 8
        button.image = image
        let tooltip = accessibilityText(provider: provider, snapshot: snapshot, hasError: hasError)
        button.toolTip = tooltip + "\nClick: switch service · Right-click: details"
        button.setAccessibilityLabel("AIUsage, \(tooltip)")
    }

    private func displayTitle(provider: ProviderID, snapshot: ProviderSnapshot?, hasError: Bool) -> String {
        let base = snapshot.map { MenuBarPresentation.title(snapshot: $0, metric: settings.metric) }
            ?? "\(provider.shortName) --"
        return hasError ? base + " !" : base
    }

    private func accessibilityText(provider: ProviderID, snapshot: ProviderSnapshot?, hasError: Bool) -> String {
        guard let snapshot else {
            return "\(provider.displayName): \(hasError ? "needs attention" : "loading")"
        }
        let values = snapshot.windows.map { window in
            let value = MenuBarPresentation.value(window, metric: settings.metric)
            let metric = settings.metric == .remaining ? "remaining" : "used"
            return "\(window.label) \(PercentFormatter.string(value)) percent \(metric)"
        }.joined(separator: ", ")
        return "\(provider.displayName): \(values)\(hasError ? ", showing stale data" : "")"
    }

    private func renderImage(
        title: String,
        snapshot: ProviderSnapshot?,
        provider: ProviderID,
        hasError: Bool) -> NSImage
    {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let prefix = provider.shortName
        let suffix = String(title.dropFirst(prefix.count))
        let prefixAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: brandColor(provider, appearance: statusItem.button?.effectiveAppearance),
        ]
        let valueColor: NSColor = hasError
            ? .systemOrange
            : snapshot == nil ? .secondaryLabelColor : severityColor(snapshot?.mostConstrainedRemaining)
        let suffixAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: valueColor]
        let attributed = NSMutableAttributedString(string: prefix, attributes: prefixAttributes)
        attributed.append(NSAttributedString(string: suffix, attributes: suffixAttributes))
        let size = attributed.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            attributed.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
    }

    private func severityColor(_ remaining: Double?) -> NSColor {
        guard let remaining else { return .secondaryLabelColor }
        switch UsageSeverity(remainingPercent: remaining) {
        case .healthy: return NSColor.systemGreen
        case .warning: return NSColor.systemOrange
        case .critical: return NSColor.systemRed
        }
    }

    private func brandColor(_ provider: ProviderID, appearance: NSAppearance?) -> NSColor {
        let dark = (appearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch provider {
        case .openCodeGo:
            return dark ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.90, alpha: 1)
                : NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.48, alpha: 1)
        case .qwen:
            return dark ? NSColor(calibratedRed: 0.68, green: 0.55, blue: 1.00, alpha: 1)
                : NSColor(calibratedRed: 0.38, green: 0.22, blue: 0.72, alpha: 1)
        case .codex:
            return dark ? NSColor(calibratedRed: 0.55, green: 0.62, blue: 1.00, alpha: 1)
                : NSColor(calibratedRed: 0.22, green: 0.27, blue: 0.68, alpha: 1)
        }
    }
}
