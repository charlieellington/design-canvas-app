// Toast notification shown when a new dev server is detected while DC is already connected
// to another project. Shows project name, port, and a "Switch" action button.
// Same design tokens as InteractHintToast — dark capsule, bottom-left positioning.

import SwiftUI

struct NewServerToast: View {

    let detector: NewServerDetector
    var onSwitch: ((DetectedServer) -> Void)?

    // Design tokens (from visual-design-references.md)
    private let surface = Color(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0)
    private let border = Color(red: 0x2C / 255.0, green: 0x2D / 255.0, blue: 0x30 / 255.0)
    private let textPrimary = Color(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0)
    private let textMuted = Color(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0)

    var body: some View {
        if let server = detector.detectedServer {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)

                Text("\(server.projectName) :\(server.port)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(textPrimary)

                Button {
                    detector.dismiss()
                    onSwitch?(server)
                } label: {
                    Text("Switch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
            .transition(.opacity)
        }
    }
}
