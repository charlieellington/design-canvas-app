// Zoom percentage display at bottom-right of the canvas. Clickable to reset to 100%.
// Design tokens: Geist Sans 12px (system font fallback), #888888 (text-muted).

import SwiftUI

struct ZoomIndicator: View {
    let camera: CanvasCamera

    @State private var isHovered = false

    var body: some View {
        let percentage = Int(camera.zoom * 100)

        Button {
            camera.zoom = 1.0
            NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
        } label: {
            Text("\(percentage)%")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundColor(
                    isHovered
                        ? Color(nsColor: NSColor(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0, alpha: 1.0))
                        : Color(nsColor: NSColor(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0, alpha: 1.0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover in isHovered = hover }
        .help("Reset to 100%")
    }
}
