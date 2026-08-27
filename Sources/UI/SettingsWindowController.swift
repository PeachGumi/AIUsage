import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: SettingsStore) {
        let content = SettingsView(settings: settings)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "AIUsage Settings"
        window.contentView = hosting
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Displayed service", selection: $settings.selectedProvider) {
                    ForEach(ProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Picker("Displayed value", selection: $settings.metric) {
                    Text("Remaining").tag(UsageMetric.remaining)
                    Text("Used").tag(UsageMetric.used)
                }
            }
            Section("Updates") {
                LabeledContent("Refresh interval", value: "5 minutes")
                Text("All services refresh in the background. The selection above only changes the menu bar display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 430, height: 280)
    }
}
