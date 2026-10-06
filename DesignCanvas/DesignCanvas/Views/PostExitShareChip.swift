// 10-second chip shown after auto-exit from Share Mode. Sits at top-right of
// the working canvas: "✓ Shared · designcanvas.app/share/xyz · [View]". Click
// the URL chunk to re-copy; click [View] to open in browser.

import AppKit
import SwiftUI

struct PostExitShareChip: View {
    @ObservedObject var coordinator: ShareModeCoordinator
    @State private var visible: Bool = false
    @State private var copiedFlash: Bool = false
    @State private var dismissTask: Task<Void, Never>?

    private let accent = Color(red: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255)
    private let surface = Color(red: 0x19 / 255, green: 0x1A / 255, blue: 0x1D / 255)
    private let textPrimary = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
    private let textMuted = Color(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255)

    var body: some View {
        Group {
            if visible, let url = coordinator.lastCreatedShareURL {
                chip(url: url)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
        .onAppear {
            scheduleVisibility()
        }
        .onChange(of: coordinator.createLinkState) { _, new in
            if case .copied = new {
                visible = true
                scheduleDismiss()
            }
        }
    }

    private func chip(url: URL) -> some View {
        HStack(spacing: 8) {
            Text(copiedFlash ? "Copied" : "✓ Shared")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(textPrimary)
            Text("·")
                .foregroundColor(textMuted)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copiedFlash = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    copiedFlash = false
                }
            } label: {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            Text("·")
                .foregroundColor(textMuted)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text("[View]")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5),
                ),
        )
        .shadow(color: Color.black.opacity(0.3), radius: 8, y: 2)
    }

    private func scheduleVisibility() {
        if coordinator.lastCreatedShareURL != nil {
            visible = true
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                visible = false
            }
        }
    }
}
