// Top-right action cluster — `[ Apply default style ▾ ] [ Share as Image ▾ ]
// [ Create Link ↗ ] [ ⋯ ]`. Strict layout per stage-14a §6: Create Link is the
// only accent-filled button; everything else is ghost. Charlie's reference
// mockups land at 14e and will sharpen polish, not change structure.

import AppKit
import SwiftUI

struct ShareModeActionCluster: View {
    @ObservedObject var coordinator: ShareModeCoordinator

    private let accent = Color(red: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255)
    private let surface = Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255)
    private let border = Color.white.opacity(0.1)
    private let textPrimary = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)

    var body: some View {
        HStack(spacing: 8) {
            ApplyDefaultStyleMenu()
            ShareAsImageMenu()
            CreateLinkButton(coordinator: coordinator)
            OverflowMenu(coordinator: coordinator)
        }
    }

    // MARK: - Apply default style

    private struct ApplyDefaultStyleMenu: View {
        var body: some View {
            Menu {
                ForEach(PresetManager.shared.presets, id: \.id) { preset in
                    Button(preset.displayName) {
                        AppServices.shared.document.styling = preset.config
                    }
                }
            } label: {
                Text("Apply default style ▾")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5),
                            ),
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Share as Image

    private struct ShareAsImageMenu: View {
        var body: some View {
            Menu {
                Button("Current view") {}
                Button("Selected area…") {}
            } label: {
                Text("Share as Image ▾")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5),
                            ),
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(true)  // Stage 21 ships the Pro export pipeline
        }
    }

    // MARK: - Create Link

    private struct CreateLinkButton: View {
        @ObservedObject var coordinator: ShareModeCoordinator
        private let accent = Color(red: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255)

        var body: some View {
            Button {
                Task { await coordinator.createLink() }
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(fillColor),
                    )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(BuildPolicy.shareBaseURL() == nil ? "Link sharing is not configured for this build." : "Create a link to the selected frames.")
        }

        private var label: String {
            switch coordinator.createLinkState {
            case .idle: return "Create Link ↗"
            case .creating(let c, let t): return "Creating… \(c)/\(t)"
            case .copied: return "✓ Copied"
            case .failed: return "✕ Failed — Retry"
            }
        }

        private var fillColor: Color {
            switch coordinator.createLinkState {
            case .failed: return .red.opacity(0.85)
            default: return accent
            }
        }

        private var disabled: Bool {
            if BuildPolicy.shareBaseURL() == nil { return true }
            if coordinator.includedFrameIDs.isEmpty { return true }
            if case .creating = coordinator.createLinkState { return true }
            return false
        }
    }

    // MARK: - Overflow

    private struct OverflowMenu: View {
        @ObservedObject var coordinator: ShareModeCoordinator

        var body: some View {
            Menu {
                Button("Refresh screenshots (⌘R)") { /* Stage 14.5b wires */ }
                if case .copied(let url) = coordinator.createLinkState {
                    Button("Customise on web ↗") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Share settings…") {}
                Divider()
                Button("Done") {
                    coordinator.exit(reason: .done)
                }
            } label: {
                Text("⋯")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5),
                            ),
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
