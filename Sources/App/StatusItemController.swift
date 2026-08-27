import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let coordinator: UsageCoordinator
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: UsageCoordinator, settings: SettingsStore, actions: AppActions) {
        self.coordinator = coordinator
        self.settings = settings
        super.init()

        let dashboard = DashboardView(coordinator: coordinator, settings: settings, actions: actions)
        popover.contentViewController = NSHostingController(rootView: dashboard)
        popover.contentSize = NSSize(width: 430, height: 640)
        popover.behavior = .transient
        popover.animates = true

        configureButton()
        observeChanges()
        render()
    }

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

    /// A menu bar click toggles the dashboard directly under the status item.
    /// Provider selection remains available by clicking a card in the popover.
    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Opening the dashboard is a strong signal that the user wants current
        // data. Avoid needless traffic when the background refresh is recent.
        Task { @MainActor [weak self] in
            await self?.coordinator.refreshIfStale(olderThan: 60)
        }
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
        button.toolTip = tooltip + "\nClick: show details"
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
