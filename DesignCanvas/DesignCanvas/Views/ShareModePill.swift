// Top-left mode pill. Three of four mode signals (cross-stage Triple-redundant
// rule); the others are accent border, toolbar fade, cursor switch.

import SwiftUI

struct ShareModePill: View {
    @ObservedObject var coordinator: ShareModeCoordinator

    private let accent = Color(red: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255)
    private let surface = Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255)
    private let textPrimary = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
    private let textMuted = Color(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255)

    var body: some View {
        HStack(spacing: 8) {
            Text("Share Mode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(textPrimary)
            Text(trailing)
                .font(.system(size: 11))
                .foregroundColor(textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accent.opacity(0.35), lineWidth: 0.5),
                ),
        )
    }

    private var trailing: String {
        if coordinator.captureOrchestrator.failureCount > 0 {
            return "· \(coordinator.captureOrchestrator.failureCount) failed · Retry all"
        }
        let active = coordinator.captureOrchestrator.activeTaskCount
        if active > 1 {
            return "· Refreshing \(active) routes"
        }
        return "· Esc to exit"
    }
}
