// Bottom-centre panel shown in demo mode: "This is a demo project | Connect your project".
// Replaces the v1 multi-CTA onboarding card in the demo state.
// See onboarding-v3-implementation.md § 4 and onboarding-v3.md § 3.1.

import SwiftUI
import AppKit

struct DemoConnectPanel: View {
    let onTap: () -> Void

    // Tokens shared with MCPSetupSheet / other surface cards
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))

    var body: some View {
        VStack(spacing: 10) {
            Text("This is a demo project")
                .font(.system(size: 12))
                .foregroundStyle(textMuted)

            Button(action: onTap) {
                Text("Connect your project")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
        )
    }
}
