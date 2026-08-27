import AppKit
import SwiftUI

struct VisualRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

enum ProviderVisuals {
    static func accentRGB(_ provider: ProviderID) -> VisualRGB {
        switch provider {
        case .openCodeGo: VisualRGB(red: 0.00, green: 0.42, blue: 0.48)
        case .qwen: VisualRGB(red: 0.38, green: 0.22, blue: 0.72)
        case .codex: VisualRGB(red: 0.22, green: 0.27, blue: 0.68)
        }
    }

    static func accent(_ provider: ProviderID) -> Color {
        accentRGB(provider).color
    }

    static func severityRGB(_ severity: UsageSeverity) -> VisualRGB {
        switch severity {
        case .healthy: VisualRGB(red: 0.05, green: 0.45, blue: 0.18)
        case .warning: VisualRGB(red: 0.70, green: 0.42, blue: 0.00)
        case .critical: VisualRGB(red: 0.75, green: 0.08, blue: 0.08)
        }
    }

    static func severity(_ severity: UsageSeverity) -> Color {
        severityRGB(severity).color
    }
}
