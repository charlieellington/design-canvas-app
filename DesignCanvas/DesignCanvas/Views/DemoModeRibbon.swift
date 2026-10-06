// Auto-fading top-of-canvas ribbon shown on first demo render per user.
// Copy locked: "Exploring a demo app — yours appears here when you connect."
// Fade-in 200ms after demo loads; auto-dismiss after 3s; once-per-user persisted flag.
// See documentation/onboarding-update-implementation.md § 5.5 (Phase 2b).

import SwiftUI
import AppKit

struct DemoModeRibbon: View {
    let isInDemoMode: Bool

    private static let shownKey = "onboardingDemoRibbonShown"

    @State private var isVisible: Bool = false
    @State private var hasTriggered: Bool = false

    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 0) {
                    Text("Exploring a demo app — yours appears here when you connect.")
                        .font(.system(size: 12))
                        .foregroundColor(textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(surface.opacity(0.95))
                        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                )
                .transition(.opacity)
                .accessibilityLabel("Demo mode notice")
                .onExitCommand { dismiss() }
            }
        }
        .onAppear { considerShowing() }
        .onChange(of: isInDemoMode) { _, _ in considerShowing() }
    }

    private func considerShowing() {
        guard isInDemoMode, !hasTriggered else { return }
        if UserDefaults.standard.bool(forKey: Self.shownKey) { return }
        hasTriggered = true

        // Fade-in 200ms after demo loads
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { isVisible = true }

            // Auto-dismiss after 3s visible
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.3)) { isVisible = false }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }
}
