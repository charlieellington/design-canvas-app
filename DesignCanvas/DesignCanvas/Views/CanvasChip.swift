// Top-left canvas chip — names the artifact the user is looking at and opens the
// canvas switcher dropdown (A1).

import SwiftUI

struct CanvasChip: View {
    var name: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x666666))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: 0x191A1D).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(hex: 0x2C2D30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
