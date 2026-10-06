// Account-switching popover anchored under the Claude usage pill. Replaces the
// silent left-click → claude.ai jump with a click-to-reveal panel that shows
// the current org, a full-width re-render of the usage bar, and three explicit
// actions (open usage page, switch account, sign out). Multi-org accounts
// also get a radio-style workspace picker above the actions.

import SwiftUI
import AppKit

struct ClaudeAccountPopover: View {
    @Bindable var service: ClaudeUsageService
    let onOpenUsagePage: () -> Void
    let onSwitchAccount: () -> Void
    let onSignOut: () -> Void
    /// Optional account-management actions. `onAddAccount` appears on account 1
    /// (while a second slot is free); `onRemoveAccount` on the second account.
    var onAddAccount: (() -> Void)? = nil
    var onRemoveAccount: (() -> Void)? = nil
    let onDismiss: () -> Void

    @State private var renderTick: Date = Date()
    @State private var hovered: String? = nil
    private let renderTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if hasUsageContent {
                divider
                usageBlock
            }

            if service.orgs.count > 1 {
                divider
                workspacePicker
            }

            divider
            actions
        }
        .frame(width: 280)
        .padding(12)
        .background(Color(hex: 0x191A1D))
        .onReceive(renderTimer) { renderTick = $0 }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(service.currentOrgName ?? "claude.ai")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xEEEEEE))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("Claude")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x888888))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }

    // MARK: - Usage block

    private var hasUsageContent: Bool {
        switch service.state {
        case .connected, .loading: return true
        default: return false
        }
    }

    @ViewBuilder
    private var usageBlock: some View {
        switch service.state {
        case .connected(let snapshot):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    UsageBar(snapshot: snapshot, now: renderTick)
                        .frame(height: 6)
                    Text(usageText(for: snapshot))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xEEEEEE))
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let reset = snapshot.displayResetsAt {
                    Text("Resets at \(absoluteResetTime(reset))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x888888))
                }
            }
            .padding(.vertical, 10)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching usage…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x888888))
            }
            .padding(.vertical, 10)

        default:
            EmptyView()
        }
    }

    // MARK: - Workspace picker (multi-org accounts only)

    @ViewBuilder
    private var workspacePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WORKSPACE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x888888))
                .padding(.top, 8)
            ForEach(service.orgs, id: \.uuid) { org in
                workspaceRow(org)
            }
        }
        .padding(.bottom, 4)
    }

    private func workspaceRow(_ org: ClaudeUsageService.Org) -> some View {
        let isSelected = service.currentOrgUUID == org.uuid
        let id = "org:\(org.uuid)"
        return Button {
            if !isSelected { service.selectOrg(org) }
            onDismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color(hex: 0x5E6AD2) : Color(hex: 0x666666))
                Text(org.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 1) {
            actionRow(
                id: "usage",
                icon: "info.circle",
                title: "Open claude.ai/settings/usage",
                trailing: "arrow.up.right"
            ) {
                onDismiss()
                onOpenUsagePage()
            }
            actionRow(
                id: "switch",
                icon: "arrow.left.arrow.right",
                title: "Switch account…",
                trailing: nil
            ) {
                onDismiss()
                onSwitchAccount()
            }
            if let onAddAccount {
                actionRow(
                    id: "add",
                    icon: "plus.circle",
                    title: "Add another account…",
                    trailing: nil
                ) {
                    onDismiss()
                    onAddAccount()
                }
            }
            actionRow(
                id: "signout",
                icon: "power",
                title: "Sign out",
                trailing: nil,
                destructive: true
            ) {
                onDismiss()
                onSignOut()
            }
            if let onRemoveAccount {
                actionRow(
                    id: "remove",
                    icon: "minus.circle",
                    title: "Remove this account",
                    trailing: nil,
                    destructive: true
                ) {
                    onDismiss()
                    onRemoveAccount()
                }
            }
        }
        .padding(.top, 6)
    }

    private func actionRow(
        id: String,
        icon: String,
        title: String,
        trailing: String?,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let textColor = destructive ? Color(hex: 0xE5484D) : Color(hex: 0xEEEEEE)
        let iconColor = destructive ? Color(hex: 0xE5484D) : Color(hex: 0x888888)
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(textColor)
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x666666))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0x2C2D30))
            .frame(height: 1)
    }

    // MARK: - Formatting

    private func usageText(for snapshot: ClaudeUsageService.Snapshot) -> String {
        let pct = Int(snapshot.displayPct.rounded())
        let suffix = snapshot.displayMode == .weekly ? " wk" : ""
        guard let reset = snapshot.displayResetsAt else { return "\(pct)%\(suffix)" }
        return "\(pct)%\(suffix) · \(timeRemaining(until: reset)) left"
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

    private func absoluteResetTime(_ reset: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: reset)
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
