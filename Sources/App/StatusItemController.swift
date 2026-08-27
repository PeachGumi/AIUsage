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
        popover.behavior = .transient
        popover.animates = true

        configureButton()
        observeChanges()
        updatePopoverSize()
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
        Publishers.CombineLatest4(
            settings.$selectedProvider,
            settings.$metric,
            settings.$registeredProviders,
            coordinator.$snapshots)
            .combineLatest(coordinator.$errors)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
                self?.render()
            }
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

        // Re-evaluate the current screen at open time in case the menu bar was
        // moved between displays. The popover grows with the number of cards
        // and only becomes scroll-constrained when it would exceed the screen.
        updatePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        Task { @MainActor [weak self] in
            await self?.coordinator.refreshIfStale(olderThan: 60)
        }
    }

    private func updatePopoverSize() {
        let screenHeight = statusItem.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 900
        popover.contentSize = NSSize(
            width: 430,
            height: Self.preferredPopoverHeight(
                providerCount: settings.registeredProviders.count,
                screenHeight: screenHeight))
    }

    /// Keep small/medium provider sets fully expanded. Scrolling is only
    /// required when the estimated natural card stack would exceed the usable
    /// display height.
    nonisolated static func preferredPopoverHeight(providerCount: Int, screenHeight: CGFloat) -> CGFloat {
        let safeScreenHeight = max(320, screenHeight - 24)
        if providerCount <= 0 {
            return min(280, safeScreenHeight)
        }
        let chromeHeight: CGFloat = 118
        let estimatedCardHeight: CGFloat = 190
        let naturalHeight = chromeHeight + CGFloat(providerCount) * estimatedCardHeight
        return min(max(320, naturalHeight), safeScreenHeight)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        guard let provider = settings.selectedProvider else {
            let image = renderEmptyImage()
            statusItem.length = image.size.width + 8
            button.image = image
            button.toolTip = "AIUsage: no providers added\nClick: add a provider"
            button.setAccessibilityLabel("AIUsage, no providers added. Click to add a provider")
            return
        }

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

    private func renderEmptyImage() -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let attributed = NSAttributedString(string: "AI +", attributes: attributes)
        let size = attributed.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            attributed.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
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
        return ProviderVisuals.severityRGB(
            UsageSeverity(remainingPercent: remaining)
        ).nsColor
    }

    private func brandColor(_ provider: ProviderID, appearance _: NSAppearance?) -> NSColor {
        ProviderVisuals.accentRGB(provider).nsColor
    }
}
