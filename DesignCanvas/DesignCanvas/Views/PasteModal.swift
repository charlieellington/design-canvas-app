// Centred paste-to-connect overlay with two states: copy (shows paste text) and
// pasted (shows "now paste into your agent" guidance). Armed via onAppear,
// dismissed via onDismiss (Esc / click-outside). See onboarding-v3-implementation.md § 4.

import SwiftUI
import AppKit

struct PasteModal: View {
    let pasteString: String
    let pasteboard: PasteboardService
    let onAppear: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var hasCopied = false
    @State private var showCopyToast = false
    @State private var showWaitingMessage = false
    @State private var waitingTask: Task<Void, Never>?

    // Design tokens
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let surfaceInset = Color(nsColor: NSColor(red: 0x12/255, green: 0x13/255, blue: 0x15/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))
    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                titleRow
                if hasCopied {
                    pastedState
                } else {
                    copyState
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(surface)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 12)
            )
            .overlay(alignment: .top) {
                if showCopyToast {
                    Text("Copied. Paste into your agent.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .offset(y: -36)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showCopyToast)
            .animation(.easeInOut(duration: 0.2), value: hasCopied)
            .animation(.easeInOut(duration: 0.2), value: showWaitingMessage)
        }
        .onAppear {
            hasCopied = false
            showWaitingMessage = false
            onAppear()
        }
        .onExitCommand { onDismiss() }
    }

    // MARK: - Title row (shared)

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Connect Design Canvas")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(textPrimary)
            Text("(one paste, any agent)")
                .font(.system(size: 13))
                .foregroundStyle(textMuted)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textMuted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - State 1: Copy

    private var copyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste this into Claude Code, Cursor, or any MCP-enabled agent:")
                .font(.system(size: 12))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            codeBlock
                .padding(.horizontal, 20)

            Button(action: handleCopy) {
                Text("Copy")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Divider()
                .overlay(border)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Text("Already have a dev server running?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textPrimary)
                .padding(.horizontal, 20)

            Text("Your app auto-detects on any local port.")
                .font(.system(size: 12))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Text("Want your team onboarded automatically? After install, commit the design-canvas block from your agent's MCP config to your repo.")
                .font(.system(size: 11, weight: .regular).italic())
                .foregroundStyle(textDimmed)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
    }

    // MARK: - State 2: Pasted

    private var pastedState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Now paste into your agent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(textPrimary)
                .padding(.horizontal, 20)

            Text("Claude Code, Cursor, or any MCP-enabled agent")
                .font(.system(size: 13))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Text("Your agent will install the MCP and start your dev server. It\u{2019}ll give you a short prompt to copy for the restart.")
                .font(.system(size: 12))
                .foregroundStyle(textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            if showWaitingMessage {
                Text("Still waiting? Check your agent is running the MCP.")
                    .font(.system(size: 12))
                    .foregroundStyle(textMuted)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                Button(action: { hasCopied = false }) {
                    Text("\u{2190} Back")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: handleCopy) {
                    Text("Copy again")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Code block

    private var codeBlock: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                Text(pasteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 200)

            Button(action: handleCopy) {
                Image(systemName: showCopyToast ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Copy")
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
    }

    private func handleCopy() {
        pasteboard.copy(pasteString)
        onCopy()
        hasCopied = true
        showCopyToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showCopyToast = false
        }
        waitingTask?.cancel()
        showWaitingMessage = false
        waitingTask = Task {
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            showWaitingMessage = true
        }
    }
}
