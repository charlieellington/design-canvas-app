// Persistent interact hint — teaches users about double-clicking to interact with frames.
// Shows as a bottom pill with a dismiss button. Stays visible until dismissed or until
// the user double-clicks a frame. Styled from visual-design-references.md tokens.

import SwiftUI

struct InteractHintToast: View {

    let coordinator: InteractHintCoordinator

    // Design tokens (from visual-design-references.md)
    private let surface = Color(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0)
    private let border = Color(red: 0x2C / 255.0, green: 0x2D / 255.0, blue: 0x30 / 255.0)
    private let textPrimary = Color(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0)
    private let textMuted = Color(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0)

    var body: some View {
        HStack(spacing: 12) {
            Text("Double-click a frame to interact with its content")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(textPrimary)

            Button {
                coordinator.dismiss()
            } label: {
                Text("\u{2715}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
        .transition(.opacity)
    }
}
