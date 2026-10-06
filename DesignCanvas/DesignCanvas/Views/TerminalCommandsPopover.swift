// What this file does (plain English):
// The popover under the terminal-commands pill. Lists Charlie's Big Terminal Mode
// commands grouped (Effort / Fast / Model / Workflow). Click a row to copy the
// command to the clipboard (then paste into the terminal); or drag the row onto a
// terminal to drop the command at the prompt, unexecuted, so he reviews before
// running. "Edit commands…" opens the backing JSON. Chrome matches
// ClaudeAccountPopover: 280pt wide, surface #191A1D, 1px #2C2D30 dividers.

import SwiftUI

struct TerminalCommandsPopover: View {
    @Bindable var store: TerminalCommandsStore
    let onDismiss: () -> Void

    @State private var hovered: String? = nil
    @State private var copiedID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(store.groups) { group in
                divider
                section(group)
            }
            divider
            editRow
        }
        .frame(width: 280)
        .padding(12)
        .background(Color(hex: 0x191A1D))
        .onAppear { store.reload() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Terminal commands")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xEEEEEE))
            Text("Click to copy · drag to insert")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x888888))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }

    // MARK: - Sections + rows

    @ViewBuilder
    private func section(_ group: TerminalCommandGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(hex: 0x888888))
                .padding(.top, 8)
            ForEach(group.commands) { cmd in
                commandRow(cmd)
            }
        }
        .padding(.bottom, 4)
    }

    // A plain tappable + draggable row (NOT a Button) so a click copies and a
    // press-drag drags the command string onto the terminal.
    private func commandRow(_ cmd: TerminalCommand) -> some View {
        let isHovered = hovered == cmd.id
        let isCopied = copiedID == cmd.id
        return HStack(spacing: 8) {
            Text(cmd.command)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: 0xEEEEEE))
                .lineLimit(1)
            Text(cmd.label)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x888888))
                .lineLimit(1)
            Spacer(minLength: 8)
            if isCopied {
                Label("Copied", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0x5E6AD2))
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: isHovered ? 0x888888 : 0x4A4B4F))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? cmd.id : nil }
        // simultaneousGesture (not onTapGesture) so a click copies even though the
        // row is also .draggable — a real drag moves the cursor, so the tap fails
        // and only the drag fires; a click with no movement fires only the tap.
        .simultaneousGesture(TapGesture().onEnded { copy(cmd) })
        .draggable(cmd.command)
    }

    private var editRow: some View {
        let id = "edit"
        return Button {
            onDismiss()
            store.openForEditing()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(Color(hex: 0x888888))
                Text("Edit commands…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                Spacer()
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
        .padding(.top, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0x2C2D30))
            .frame(height: 1)
    }

    // MARK: - Actions

    private func copy(_ cmd: TerminalCommand) {
        SystemPasteboard().copy(cmd.command)
        copiedID = cmd.id
        // Clear the ✓ after a moment, without dismissing the popover (so the user
        // can copy several commands in a row).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == cmd.id { copiedID = nil }
        }
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
