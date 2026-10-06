// Consent toast for the "server moved ports" case. When a stale ServerBinding's
// project identity matches a newly-detected port (strong/medium tier), surface
// a one-click rebind under the right-side pill. Weak matches surface only as a
// passive option in the pill popover (no toast — Conductor worktree case).
//
// The rebind action mutates the existing binding's origin/port/status in place,
// not a new binding id, so routes pointing at this binding pick up the new port
// without their UUIDs changing.

import SwiftUI

struct PortRebindCandidate: Identifiable, Equatable {
    let id: UUID                  // binding id
    let displayName: String
    let oldPort: Int?
    let newPort: Int
    let affectedRouteCount: Int

    static func == (l: Self, r: Self) -> Bool {
        l.id == r.id && l.newPort == r.newPort
    }
}

struct PortRebindToast: View {
    let candidate: PortRebindCandidate
    var onRebind: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0x888888))

            VStack(alignment: .leading, spacing: 2) {
                let oldPart = candidate.oldPort.map { " moved from :\($0)" } ?? ""
                Text("`\(candidate.displayName)` looks like it\(oldPart) to :\(candidate.newPort).")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)
                Text("Rebind \(candidate.affectedRouteCount) route\(candidate.affectedRouteCount == 1 ? "" : "s")?")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x888888))
            }

            Spacer(minLength: 12)

            Button(action: onRebind) {
                Text("Rebind")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: 0x5E6AD2))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onIgnore) {
                Text("Ignore")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x888888))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x191A1D))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(hex: 0x2C2D30), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
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
