import SwiftUI

enum ProviderVisuals {
    static func accent(_ provider: ProviderID) -> Color {
        switch provider {
        case .openCodeGo: Color(red: 0.05, green: 0.62, blue: 0.66)
        case .qwen: Color(red: 0.48, green: 0.32, blue: 0.88)
        case .codex: Color(red: 0.31, green: 0.36, blue: 0.82)
        }
    }

    static func severity(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .healthy: Color(red: 0.40, green: 0.90, blue: 0.50)
        case .warning: Color(red: 1.00, green: 0.80, blue: 0.30)
        case .critical: Color(red: 1.00, green: 0.45, blue: 0.40)
        }
    }
}
