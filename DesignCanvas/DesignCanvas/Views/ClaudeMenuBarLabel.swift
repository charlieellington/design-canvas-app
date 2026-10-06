// Menu bar pill — the system-status-item sibling of ClaudeUsagePill. Renders
// `"M 67% · 2h"` for connected accounts, decaying every 30s, and a muted
// SF Symbol for every other state. Clicking opens ClaudeAccountPopover (the
// same panel the in-window pill uses).
//
// State coverage matches ClaudeUsageService.State 1:1. .unauthenticated keeps
// the menu bar item visible so the user can sign in from any app — the
// popover's "Switch account…" row routes back through onSwitchAccount to
// reopen the canvas window and present ClaudeLoginSheet.

import SwiftUI
import AppKit

enum ClaudeMenuBarFormatter {
    static func accountPrefix(label: String?, isVisible: Bool) -> String {
        guard isVisible, let label else { return "" }
        switch label {
        case ClaudeAccountsManager.primaryLabel: return "M "
        case ClaudeAccountsManager.secondLabel: return "2 "
        default: return "\(label) "
        }
    }

    static func usageText(for snapshot: ClaudeUsageService.Snapshot, now: Date) -> String {
        let pct = Int(snapshot.displayPct.rounded())
        guard let reset = snapshot.displayResetsAt else { return "\(pct)%" }
        return "\(pct)% · \(CompactUsageCountdownFormatter.string(until: reset, now: now))"
    }
}

// MARK: - ClaudeMenuBarLabel

struct ClaudeMenuBarLabel: View {
    @Bindable var service: ClaudeUsageService
    /// When two accounts are tracked, prefix the text with a short account label
    /// so the two menu bar items are distinguishable.
    var showAccountLabel: Bool = false

    @State private var renderTick: Date = Date()
    private let renderTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch service.state {
            case .connected(let snapshot):
                Text(
                    ClaudeMenuBarFormatter.accountPrefix(
                        label: service.accountLabel,
                        isVisible: showAccountLabel
                    )
                    + ClaudeMenuBarFormatter.usageText(for: snapshot, now: renderTick)
                )
                    .foregroundStyle(textColor(for: snapshot))
            case .loading:
                Image(systemName: "ellipsis")
            case .unauthenticated:
                Image(systemName: "key.fill")
            case .freeTier:
                Image(systemName: "person.crop.circle")
            case .error:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .onReceive(renderTimer) { renderTick = $0 }
    }

    /// Red tint only inside the final 5-minute pulse window of an active
    /// session — everything else stays the system default so the menu bar
    /// text blends with neighbouring items. The burn-state colour from the
    /// in-window pill is intentionally not used here: the status bar already
    /// renders text against an arbitrary wallpaper, and brand orange on top
    /// of that fails contrast.
    private func textColor(for snapshot: ClaudeUsageService.Snapshot) -> Color {
        guard snapshot.displayMode == .session, let reset = snapshot.fiveHourResetsAt else {
            return .primary
        }
        let secs = reset.timeIntervalSince(renderTick)
        if secs > 0, secs < 5 * 60 { return Color(hex: 0xE5484D) }
        return .primary
    }
}

// MARK: - ClaudeMenuBarPopover

/// Thin wrapper around ClaudeAccountPopover that routes the sign-in path
/// through `openWindow(id: "canvas")` + the App-level `showClaudeLoginSheet`
/// state, so the menu bar entry point works whether or not the canvas window
/// is currently open.
struct ClaudeMenuBarPopover: View {
    @Bindable var service: ClaudeUsageService
    /// Set the app-level login target for this account. The popover wraps it with
    /// the window-reveal choreography so the sheet has a host window even when the
    /// user came from the menu bar with the canvas window closed.
    var onRequestLogin: () -> Void
    var onAddAccount: (() -> Void)?
    var onRemoveAccount: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ClaudeAccountPopover(
            service: service,
            onOpenUsagePage: {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            },
            onSwitchAccount: {
                // Wipe cookies then open a cold login sheet for this account so
                // claude.ai shows the sign-in form, not an auto-redirect.
                service.signOut()
                presentInCanvas { onRequestLogin() }
            },
            onSignOut: { service.signOut() },
            onAddAccount: onAddAccount.map { add in { presentInCanvas(add) } },
            onRemoveAccount: onRemoveAccount,
            onDismiss: { }
        )
    }

    /// Reveal the canvas window (the login sheet's host) before running an action
    /// that ends in presenting the login sheet, regardless of menu bar entry.
    private func presentInCanvas(_ action: @escaping () -> Void) {
        openWindow(id: "canvas")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { action() }
    }
}

// MARK: - Hex helper

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
