// Top-left card shown when ReloadStormDetector flips to paused. Surfaces the
// reload count and offers manual escape: ↻ (refresh once, stays paused — peek)
// or ▶ (resume, exiting pause and triggering one catch-up reload). Lives next
// to CanvasChip in the topLeading VStack — see DesignCanvasApp body.

import SwiftUI

struct PausedStatusCard: View {
    let detector: ReloadStormDetector

    @State private var dotPulse = false
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: 0x5E6AD2))
                .frame(width: 7, height: 7)
                .scaleEffect(dotPulse ? 1.25 : 1.0)
                .opacity(dotPulse ? 0.5 : 1.0)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: dotPulse
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Live updates paused")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                Text("\(detector.recentCount) reloads in \(Int(ReloadStormDetector.stormWindow))s")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }

            Rectangle()
                .fill(Color(hex: 0x2C2D30))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            iconButton(
                icon: "arrow.clockwise",
                tooltip: "Refresh now (stays paused)",
                action: { detector.forceRefreshAll() }
            )
            iconButton(
                icon: "play.fill",
                tooltip: "Resume live updates",
                action: { detector.resume(reloadFrames: true, source: "manual play") }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: 0x191A1D).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(hex: 0x5E6AD2).opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .onAppear { dotPulse = true }
    }

    private func iconButton(
        icon: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    hovered == icon
                        ? Color(hex: 0xEEEEEE)
                        : Color(hex: 0x888888)
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? icon : nil }
        .help(tooltip)
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
