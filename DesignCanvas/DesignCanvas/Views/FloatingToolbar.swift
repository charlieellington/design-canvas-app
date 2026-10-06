// Pill-shaped floating toolbar at bottom centre of the canvas. Contains add (opens ⌘K
// command palette), refresh all, and zoom-to-fit. Markdown/image adds live inside the
// palette — see CommandPaletteMarkdownPicker and CommandPaletteImagePicker.
// Design tokens from visual-design-references.md — surface #191A1D, border 1px #2C2D30,
// radius 99px (capsule), shadow 0 8px 24px rgba(0,0,0,0.4).

import AppKit
import SwiftUI

struct FloatingToolbar: View {
    let camera: CanvasCamera
    let document: DocumentModel
    let mcpState: MCPConnectionState

    @State private var hoveredButton: String?

    var body: some View {
        HStack(spacing: 0) {
            // Add button — opens the ⌘K command palette
            toolbarButton(
                id: "add",
                icon: "plus",
                tooltip: "Add (⌘K)"
            ) {
                AppServices.shared.paletteState.open()
            }

            divider

            // Refresh all: reload live frames + recapture screenshots. If a
            // storm pause is active, also resume normal HMR.
            toolbarButton(
                id: "refresh",
                icon: "arrow.clockwise",
                tooltip: "Refresh All (resumes if paused)"
            ) {
                let services = AppServices.shared
                if services.stormDetector.isPaused {
                    services.stormDetector.resume(reloadFrames: false, source: "toolbar refresh")
                }
                services.stormDetector.forceRefreshAll()
            }

            divider

            // Zoom to fit all frames
            toolbarButton(
                id: "zoomfit",
                icon: "arrow.up.left.and.arrow.down.right",
                tooltip: "Zoom to Fit"
            ) {
                NotificationCenter.default.post(
                    name: Notification.Name("zoomToFitAll"),
                    object: nil
                )
            }

            // Phase 7 (onboarding-update-implementation.md § 10.2): MCP button removed from
            // the toolbar — the onboarding card now owns the primary install surface. The
            // MCPSetupSheet remains accessible via ⌘⇧M as a power-user fallback.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(nsColor: NSColor(
                    red: 0x19 / 255.0,
                    green: 0x1A / 255.0,
                    blue: 0x1D / 255.0,
                    alpha: 1.0
                )))
                .overlay(
                    Capsule()
                        .strokeBorder(Color(nsColor: NSColor(
                            red: 0x2C / 255.0,
                            green: 0x2D / 255.0,
                            blue: 0x30 / 255.0,
                            alpha: 1.0
                        )), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
        )
    }

    private func toolbarButton(
        id: String,
        icon: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(
                    hoveredButton == id
                        ? Color(nsColor: NSColor(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0, alpha: 1.0))
                        : Color(nsColor: NSColor(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0, alpha: 1.0))
                )
                .frame(width: 32, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredButton = isHovered ? id : nil
        }
        .help(tooltip)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor(
                red: 0x2C / 255.0,
                green: 0x2D / 255.0,
                blue: 0x30 / 255.0,
                alpha: 1.0
            )))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

}
