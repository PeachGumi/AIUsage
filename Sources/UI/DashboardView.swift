import SwiftUI

@MainActor
struct AppActions {
    let refreshAll: () -> Void
    let refresh: (ProviderID) -> Void
    let login: (ProviderID) -> Void
    let logout: (ProviderID) -> Void
    let openDashboard: (ProviderID) -> Void
    let showSettings: () -> Void
    let quit: () -> Void
}

/// Main window content: one card per provider, all visible without scrolling.
/// Clicking a card makes that provider the menu bar one; cards reorder by drag.
struct DashboardView: View {
    @ObservedObject var coordinator: UsageCoordinator
    @ObservedObject var settings: SettingsStore
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // List gives native drag-to-reorder (onMove); scrollDisabled keeps
            // every card visible without scrolling.
            List {
                ForEach(settings.providerOrder, id: \.self) { provider in
                    ProviderCard(
                        provider: provider,
                        snapshot: coordinator.snapshots[provider],
                        error: coordinator.errors[provider],
                        refreshing: coordinator.refreshing.contains(provider),
                        metric: settings.metric,
                        isSelected: settings.selectedProvider == provider,
                        actions: actions,
                        select: { settings.selectedProvider = provider })
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 6)
                }
                .onMove { source, destination in
                    settings.moveProvider(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .padding(.horizontal, 10)
            footer
        }
        .frame(width: 430)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage").font(.headline)
                Text("Click a card to pin it to the menu bar").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: actions.refreshAll) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh all providers")
            .accessibilityLabel("Refresh all providers")
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button("Settings", systemImage: "gearshape", action: actions.showSettings)
                .buttonStyle(.borderless)
            Spacer()
            Text("Drag the grip to reorder").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Quit", action: actions.quit)
                .buttonStyle(.borderless)
        }
        .padding(12)
    }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let error: String?
    let refreshing: Bool
    let metric: UsageMetric
    let isSelected: Bool
    let actions: AppActions
    let select: () -> Void

    var body: some View {
        card
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                isSelected ? ProviderVisuals.accent(provider).opacity(0.7) : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 1.5 : 1))
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeader
            if let snapshot {
                ForEach(snapshot.windows) { window in
                    UsageWindowRow(window: window, metric: metric)
                }
            } else if error == nil {
                placeholder
            }
            if let error { errorView(error) }
            if let fetchedAt = snapshot?.fetchedAt {
                HStack(spacing: 5) {
                    Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                    if error != nil { Text("· stale").foregroundStyle(.orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            cardActions
        }
        .padding(13)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Sets this provider as the menu bar display")
        .accessibilityAction(named: "Pin to menu bar", select)
        // Card tap-through: the card background area (not its buttons) selects
        // the provider. Buttons inside swallow taps first, so they still work.
        .onTapGesture(perform: select)
    }

    private var accessibilitySummary: String {
        let status = error != nil ? "needs attention" : snapshot == nil ? "loading" : "available"
        return "\(provider.displayName), \(status)\(isSelected ? ", shown in menu bar" : "")"
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            Text(provider.shortName)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 24)
                .background(ProviderVisuals.accent(provider), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                if let plan = snapshot?.planName { Text(plan).font(.caption2).foregroundStyle(.secondary) }
            }
            if isSelected {
                Label("Menu bar", systemImage: "menubar.rectangle")
                    .font(.caption2)
                    .foregroundStyle(ProviderVisuals.accent(provider))
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(error == nil && snapshot != nil ? Color.green : error == nil ? Color.gray : Color.orange)
            .frame(width: 8, height: 8)
            .accessibilityLabel(error == nil && snapshot != nil ? "Available" : error == nil ? "Waiting" : "Needs attention")
    }

    private var placeholder: some View {
        Text(refreshing ? "Fetching usage…" : "No usage data yet")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardActions: some View {
        HStack(spacing: 14) {
            Button("Refresh") { actions.refresh(provider) }.buttonStyle(.link)
            if provider != .codex {
                if error == nil && snapshot != nil {
                    Button("Sign out") { actions.logout(provider) }.buttonStyle(.link)
                } else {
                    Button("Sign in") { actions.login(provider) }.buttonStyle(.link)
                }
            }
            Spacer()
            Button("Open dashboard") { actions.openDashboard(provider) }.buttonStyle(.link)
        }
        .font(.caption)
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Text(valueText).font(.system(.caption, design: .monospaced, weight: .semibold))
            }
            // The bar always visualizes remaining quota and is labeled as
            // such, independent of the numeric metric setting.
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(ProviderVisuals.severity(UsageSeverity(remainingPercent: window.remainingPercent)))
                .accessibilityLabel(window.label)
                .accessibilityValue("Remaining \(PercentFormatter.string(window.remainingPercent)) percent")
            if let resetText {
                Text(resetText).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        let value = MenuBarPresentation.value(window, metric: metric)
        let suffix = metric == .remaining ? "left" : "used"
        return "\(PercentFormatter.string(value))% \(suffix)"
    }

    private var resetText: String? {
        if let description = window.resetDescription { return description }
        guard let date = window.resetsAt else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
