// Top-right dev-server pill — names the runtime the active canvas is plugged into.
// Sits to the left of the Claude pill. Replaces the top-left workspace chip
// (ServerStatusPill). Three states:
//   connected — `● :3000 · my-app`         (solid green dot, monospace port + project name)
//   none      — `○ Connect server`         (muted dot, plain label)
//   demo      — `○ Connect server` + indigo pulse (same animation the old left chip used)
//
// In B0 the pill backs onto a single DevServerManager. C0 replaces that with a
// DevServerRegistry so multiple bound servers can surface as `● 2 servers`.

import SwiftUI

struct DevServerPill: View {
    let devServer: DevServerManager
    var isInDemoMode: Bool = false
    var demoDetectedServers: [DetectedServer] = []
    var onTap: () -> Void

    // First-appear bounce + repeating pulse (only during demo with no live server yet).
    @State private var firstAppearScale: CGFloat = 1.0
    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: isInDemoMode && !hasDemoCandidate ? 8 : 6) {
                statusDot
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x666666))
                }
            }
            .padding(.horizontal, isInDemoMode && !hasDemoCandidate ? 14 : 10)
            .padding(.vertical, isInDemoMode && !hasDemoCandidate ? 7 : 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(pillBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(firstAppearScale)
        }
        .buttonStyle(.plain)
        .onAppear {
            if isInDemoMode && demoDetectedServers.isEmpty {
                triggerFirstAppearPulse()
            }
        }
        .onChange(of: demoDetectedServers.count) { _, newCount in
            isPulsing = isInDemoMode && newCount > 0
        }
        .animation(.easeInOut(duration: 0.3), value: isInDemoMode)
        .animation(.easeInOut(duration: 0.3), value: demoDetectedServers.count)
    }

    // MARK: - Computed visuals

    private var hasDemoCandidate: Bool { !demoDetectedServers.isEmpty }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: dotSize, height: dotSize)
            .overlay {
                // While in demo and one or more real servers have been detected, the dot
                // gets an outward green ripple so the pill reads as "ready — click to switch".
                if isInDemoMode && hasDemoCandidate {
                    Circle()
                        .stroke(Color.green.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isPulsing ? 2.0 : 1.0)
                        .opacity(isPulsing ? 0 : 1)
                        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
                }
            }
    }

    private var dotSize: CGFloat {
        isInDemoMode && !hasDemoCandidate ? 8 : 7
    }

    private var dotColor: Color {
        if isInDemoMode {
            return hasDemoCandidate ? .green : Color(hex: 0x5E6AD2)
        }
        switch devServer.status {
        case .running:            return .green
        case .starting, .probing: return .orange
        case .failed:             return Color(hex: 0xE5484D)
        case .disconnected:       return Color(hex: 0x666666)
        }
    }

    private var label: String {
        if isInDemoMode {
            if !hasDemoCandidate {
                return "Connect server"
            } else if demoDetectedServers.count == 1 {
                let s = demoDetectedServers[0]
                return "\(s.projectName) :\(s.port) found · Switch →"
            } else {
                return "\(demoDetectedServers.count) servers found · Choose →"
            }
        }
        switch devServer.status {
        case .running:
            if let dir = devServer.projectDir {
                let name = (dir as NSString).lastPathComponent
                return ":\(devServer.port) · \(name)"
            }
            return ":\(devServer.port)"
        case .starting:           return "Starting…"
        case .probing:            return "Checking…"
        case .failed(let m):      return String(m.prefix(30))
        case .disconnected:       return "Connect server"
        }
    }

    private var labelFont: Font {
        if isInDemoMode && !hasDemoCandidate {
            return .system(size: 13, weight: .medium)
        }
        return .system(size: 11, weight: .medium, design: .monospaced)
    }

    private var showsChevron: Bool {
        // No chevron during the indigo-pulse "Connect server" state — the affordance is
        // the pulse itself, and a chevron would compete with it. Same call the old left
        // chip made.
        !(isInDemoMode && !hasDemoCandidate)
    }

    private var pillBackground: Color {
        if isInDemoMode && !hasDemoCandidate {
            return Color(hex: 0x5E6AD2).opacity(0.15)
        }
        return Color(hex: 0x191A1D).opacity(0.9)
    }

    private var borderColor: Color {
        if isInDemoMode && !hasDemoCandidate {
            return Color(hex: 0x5E6AD2).opacity(0.3)
        }
        return Color(hex: 0x2C2D30)
    }

    // MARK: - First-appear pulse

    /// Three subtle scale bursts to draw the eye to the indigo "Connect server" state
    /// when demo loads cold. Same shape as the previous left-chip behaviour.
    private func triggerFirstAppearPulse() {
        for i in 0..<3 {
            let delay = Double(i) * 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.3)) { firstAppearScale = 1.05 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) {
                withAnimation(.easeInOut(duration: 0.3)) { firstAppearScale = 1.0 }
            }
        }
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
