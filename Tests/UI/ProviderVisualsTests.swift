import SwiftUI
import XCTest
@testable import AIUsage

final class ProviderVisualsTests: XCTestCase {
    func testSeverityColorsMatchGoUsagePalette() {
        // GoUsage palette (shared by both appearances in the popover context):
        // green (0.40, 0.90, 0.50), yellow (1.0, 0.80, 0.30), red (1.0, 0.45, 0.40).
        let healthy = ProviderVisuals.severity(.healthy).rgbComponents
        let warning = ProviderVisuals.severity(.warning).rgbComponents
        let critical = ProviderVisuals.severity(.critical).rgbComponents

        XCTAssertTrue(zip(healthy, [0.40, 0.90, 0.50]).allSatisfy { abs($0.0 - $0.1) < 0.001 },
                      "healthy \(healthy)")
        XCTAssertTrue(zip(warning, [1.00, 0.80, 0.30]).allSatisfy { abs($0.0 - $0.1) < 0.001 },
                      "warning \(warning)")
        XCTAssertTrue(zip(critical, [1.00, 0.45, 0.40]).allSatisfy { abs($0.0 - $0.1) < 0.001 },
                      "critical \(critical)")
    }
}

private extension Color {
    /// Extracts sRGB components in the current appearance. On macOS SwiftUI
    /// `Color` bridges to `NSColor`; resolved components are read directly.
    var rgbComponents: [Double] {
        let nsColor = NSColor(self)
        guard let converted = nsColor.usingColorSpace(.sRGB) else {
            return []
        }
        return [Double(converted.redComponent),
                Double(converted.greenComponent),
                Double(converted.blueComponent)]
    }
}
