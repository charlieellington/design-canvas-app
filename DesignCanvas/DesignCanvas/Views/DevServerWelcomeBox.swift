// First-launch welcome box for the Peter path (dev server detected). Persistent
// dismiss flag (onboardingWelcomeBoxShown) lives in the reducer — this view is pure.
// See onboarding-v3-implementation.md § 4 and onboarding-v3.md § 3.2.

import SwiftUI
import AppKit

struct DevServerWelcomeBox: View {
    let onClose: () -> Void
    let onInstallPlugin: () -> Void

    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))

    var body: some View {
        VStack(spacing: 14) {
            Text("Welcome! Explore the app and control it with any agent.")
                .font(.system(size: 13))
                .foregroundStyle(textPrimary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                // Primary (solid accent): Close — Peter already has the wow.
                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(accent)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                // Secondary (outlined): Install MCP
                Button(action: onInstallPlugin) {
                    Text("Install MCP")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
        )
    }
}
