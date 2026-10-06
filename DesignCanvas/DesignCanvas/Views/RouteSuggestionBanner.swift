// Non-blocking banner shown once after first real project connection.
// "Found N routes · Add to canvas" — dismissed via UserDefaults flag.

import SwiftUI

struct RouteSuggestionBanner: View {
    let addableCount: Int
    var onAdd: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 0.9))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))

    var body: some View {
        HStack(spacing: 8) {
            Text("Found \(addableCount) routes")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textPrimary)

            Button("Add to canvas") {
                onAdd?()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accent)
            .buttonStyle(.plain)

            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(border, lineWidth: 1)
        )
    }
}
