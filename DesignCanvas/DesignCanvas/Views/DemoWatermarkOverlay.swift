// Diagonal "DEMO APP" watermark drawn over each demo frame.
// Rotated ~-20°, opacity ~0.10, sized relative to the frame rect so it stays legible
// at any canvas zoom. Gated on services.demo.isInDemoMode.
// See documentation/onboarding-update-implementation.md § 5.5 (Phase 2b).

import SwiftUI
import AppKit

struct DemoWatermarkOverlay: View {

    private let textColor = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))

    var body: some View {
        GeometryReader { geo in
            let fontSize = max(min(geo.size.width, geo.size.height) * 0.18, 48)
            Text("DEMO APP")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(textColor)
                .opacity(0.10)
                .rotationEffect(.degrees(-20))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
