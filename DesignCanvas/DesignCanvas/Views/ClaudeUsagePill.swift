// Top-right status pill — shows current Claude 5-hour utilization + time to
// reset, with a 40pt capsule whose colour reflects burn-rate balance (not just
// absolute usage). Matches DevServerPill chrome (its sibling to the left).
//
// Bar colours:
//   orange — balanced burn (Anthropic Orange #D97757)
//   amber  — under- or over-burn (≥30% elapsed and projected <80% or >130%)
//   red    — at-cap (≥90%) or <5m to reset
// Pill chrome stays neutral so a red bar reads as "Claude usage critical",
// not "the server is broken" (DevServerPill already owns red for failure).

import SwiftUI
import AppKit

struct ClaudeUsagePill: View {
    @Bindable var service: ClaudeUsageService
    /// When two accounts are tracked, prefix the text with a short account label
    /// (first 3 letters of the email) so the two pills are distinguishable.
    var showAccountLabel: Bool = false
    var onLoginTap: () -> Void
    var onSwitchAccount: () -> Void
    /// Optional account-management actions surfaced in the popover. `onAddAccount`
    /// is set on account 1 (while a slot is free); `onRemoveAccount` on account 2.
    var onAddAccount: (() -> Void)? = nil
    var onRemoveAccount: (() -> Void)? = nil

    /// Re-render every 30s so the time-remaining text decays even when the
    /// poller hasn't fired (the snapshot is fresh, but `now` keeps moving).
    @State private var renderTick: Date = Date()
    @State private var isPopoverPresented = false
    private let renderTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: handlePrimaryTap) {
            content
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
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            ClaudeAccountPopover(
                service: service,
                onOpenUsagePage: { openUsagePage() },
                onSwitchAccount: { onSwitchAccount() },
                onSignOut: { confirmSignOut() },
                onAddAccount: onAddAccount,
                onRemoveAccount: onRemoveAccount,
                onDismiss: { isPopoverPresented = false }
            )
        }
        .contextMenu { contextMenu }
        .onReceive(renderTimer) { renderTick = $0 }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .unauthenticated:
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x666666))
                Text("Sign in to track Claude usage")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }

        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Claude usage…")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }

        case .connected(let snapshot):
            HStack(spacing: 8) {
                UsageBar(snapshot: snapshot, now: renderTick)
                    .frame(width: 40, height: 8)
                Text(labelPrefix + usageText(for: snapshot))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor(for: snapshot))
            }

        case .freeTier:
            // Single-org Free-tier accounts are hidden by the parent; we only
            // render here for multi-org users who picked an org with no 5-hour
            // data. Show the org name + a hint so the workspace picker (opened
            // on tap) is the obvious next step.
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x666666))
                Text(service.currentOrgName ?? "No usage data")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }

        case .error:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: 0x666666))
                    .frame(width: 7, height: 7)
                Text("Claude — offline")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Refresh now") { service.refreshNow() }
        Divider()
        Button("Hide for this session") { service.sessionHidden = true }
        Button("Hide permanently…") { confirmHidePermanently() }
    }

    // MARK: - Actions

    private func handlePrimaryTap() {
        switch service.state {
        case .unauthenticated:
            onLoginTap()
        case .error:
            service.refreshNow()
        case .connected, .loading, .freeTier:
            // .freeTier reaches here only for multi-org users — opening the
            // popover surfaces the workspace picker so they can switch back.
            isPopoverPresented = true
        }
    }

    private func openUsagePage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func confirmHidePermanently() {
        let alert = NSAlert()
        alert.messageText = "Hide Claude usage pill?"
        alert.informativeText = "You can re-enable it from View → Show Claude Usage."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            service.permanentlyHidden = true
        }
    }

    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of claude.ai?"
        alert.informativeText = "You'll stop seeing Claude usage here until you sign back in."
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            service.signOut()
        }
    }

    // MARK: - Formatting

    /// Short per-account label (e.g. "cha ") shown only when more than one account
    /// is tracked, so the two pills can be told apart. Empty otherwise.
    private var labelPrefix: String {
        guard showAccountLabel, let label = service.accountLabel else { return "" }
        return "\(label) "
    }

    private func usageText(for snapshot: ClaudeUsageService.Snapshot) -> String {
        let pct = Int(snapshot.displayPct.rounded())
        let suffix = snapshot.displayMode == .weekly ? " wk" : ""
        guard let reset = snapshot.displayResetsAt else { return "\(pct)%\(suffix)" }
        return "\(pct)%\(suffix) · \(timeRemaining(until: reset))"
    }

    private func timeRemaining(until reset: Date) -> String {
        let secs = max(0, reset.timeIntervalSince(renderTick))
        let totalMinutes = Int(secs / 60)
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return "\(totalHours)h \(minutes)m"
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        return "\(days)d \(hours)h"
    }

    private func textColor(for snapshot: ClaudeUsageService.Snapshot) -> Color {
        guard snapshot.displayMode == .session, let reset = snapshot.fiveHourResetsAt else {
            return Color(hex: 0xEEEEEE)
        }
        let secs = reset.timeIntervalSince(renderTick)
        if secs > 0, secs < 5 * 60 { return Color(hex: 0xE5484D) }
        return Color(hex: 0xEEEEEE)
    }
}

// MARK: - UsageBar

struct UsageBar: View {
    let snapshot: ClaudeUsageService.Snapshot
    let now: Date

    @State private var pulseOpacity: Double = 1.0

    /// Weekly cap is invisible to the user until they open the popover; surface
    /// it on the pill only once it's in critical territory so the warning
    /// reads as "act now", not chrome.
    private static let weeklyAlertThreshold: Double = 90

    // Stacked weekly-alert bar only stacks in .session mode — in .weekly mode
    // the primary bar already represents weekly usage, no need to double up.
    private var weeklyAlertFraction: Double? {
        guard snapshot.displayMode == .session,
              let pct = snapshot.sevenDayPct,
              pct >= Self.weeklyAlertThreshold else { return nil }
        return min(max(pct / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            if let weeklyFraction = weeklyAlertFraction {
                VStack(spacing: 2) {
                    capsule(width: geo.size.width, fraction: weeklyFraction, color: Color(hex: 0xE5484D), pulse: false)
                    primaryCapsule(width: geo.size.width)
                }
            } else {
                primaryCapsule(width: geo.size.width)
            }
        }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: shouldPulse) { _, new in
            if new { startPulseIfNeeded() } else { pulseOpacity = 1.0 }
        }
    }

    private func primaryCapsule(width: CGFloat) -> some View {
        let fillFraction = min(max(snapshot.displayPct / 100, 0), 1)
        return capsule(width: width, fraction: fillFraction, color: colorForBurnState, pulse: shouldPulse)
    }

    private func capsule(width: CGFloat, fraction: Double, color: Color, pulse: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(hex: 0x2C2D30))
            Capsule()
                .fill(color)
                .frame(width: width * fraction)
                .opacity(pulse ? pulseOpacity : 1.0)
        }
    }

    private var shouldPulse: Bool {
        // Pulse only inside the 5-minute reset countdown of an active session.
        guard snapshot.displayMode == .session,
              let reset = snapshot.fiveHourResetsAt else { return false }
        let secs = reset.timeIntervalSince(now)
        return secs > 0 && secs < 5 * 60
    }

    private func startPulseIfNeeded() {
        guard shouldPulse else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.4
        }
    }

    private var colorForBurnState: Color {
        // Weekly fallback: no burn-rate projection — just "amount used".
        if snapshot.displayMode == .weekly {
            return snapshot.displayPct >= 90 ? Color(hex: 0xE5484D) : Color(hex: 0xD97757)
        }
        // Session mode.
        let pct = snapshot.fiveHourPct
        if pct >= 90 { return Color(hex: 0xE5484D) }            // at-cap red
        guard let elapsed = snapshot.elapsedFraction(now: now), elapsed >= 0.30,
              let projected = snapshot.projectedEndOfPeriod(now: now) else {
            return Color(hex: 0xD97757)                         // Anthropic Orange
        }
        if projected < 80 || projected > 130 {
            return Color(hex: 0xE5A600)                         // amber: imbalanced burn
        }
        return Color(hex: 0xD97757)
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
