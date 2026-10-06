// Workspace switcher panel — shows running dev servers and saved layouts. Opened by clicking
// the workspace chip (top-left) or pressing ⌘T. Design tokens from visual-design-references.md.

import SwiftUI

struct WorkspaceSwitcher: View {
    @Bindable var state: WorkspaceSwitcherState
    var onSelectRunning: ((DetectedServer) -> Void)?
    var onSelectRecent: ((CanvasState) -> Void)?
    var onConnectToPort: ((Int) -> Void)?
    var onSetupMCP: (() -> Void)?

    @FocusState private var isSearchFocused: Bool
    @State private var showManualPort = false
    @State private var manualPortText = ""

    // Design tokens
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            VStack(alignment: .leading, spacing: 0) {
                searchField
                divider

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        runningSection
                        recentSection

                        if state.filteredRunning.isEmpty && state.filteredRecent.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)

                divider
                manualPortRow
                setupMCPRow
            }
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 44)
            .padding(.leading, 12)
        }
        .onAppear { isSearchFocused = true }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(textDimmed)
                .font(.system(size: 14))

            TextField("Search workspaces…", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(textPrimary)
                .focused($isSearchFocused)

            Text("⌘T")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(textDimmed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(border).frame(height: 1)
    }

    // MARK: - Running section

    @ViewBuilder
    private var runningSection: some View {
        let servers = state.filteredRunning
        if !servers.isEmpty {
            sectionHeader("Running")
            ForEach(servers) { server in
                runningRow(server)
            }
        }
    }

    private func runningRow(_ server: DetectedServer) -> some View {
        let isCurrent = server.port == state.activePort
        let routeCount = state.savedRouteCount(for: server)
        return Button {
            state.close()
            onSelectRunning?(server)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)

                Text(server.projectName)
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(":\(server.port)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textMuted)

                if let count = routeCount {
                    Text("\(count) routes")
                        .font(.system(size: 11))
                        .foregroundColor(textDimmed)
                }

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textMuted)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCurrent ? Color.white.opacity(0.04) : Color.clear)
    }

    // MARK: - Recent section

    @ViewBuilder
    private var recentSection: some View {
        let recents = state.filteredRecent
        if !recents.isEmpty {
            sectionHeader("Recent")
            ForEach(recents, id: \.projectDir) { saved in
                recentRow(saved)
            }
        }
    }

    private func recentRow(_ saved: CanvasState) -> some View {
        RecentRowView(
            saved: saved,
            textMuted: textMuted,
            textDimmed: textDimmed,
            onSelect: {
                state.close()
                onSelectRecent?(saved)
            },
            onDelete: {
                state.deleteRecent(projectDir: saved.projectDir)
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No dev servers found")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textPrimary)

            Text("Start your dev server and we'll\ndetect it automatically.")
                .font(.system(size: 12))
                .foregroundColor(textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Manual port fallback

    private var manualPortRow: some View {
        Group {
            if showManualPort {
                HStack(spacing: 8) {
                    Text("Port")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textMuted)

                    TextField("3000", text: $manualPortText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .onSubmit { commitManualPort() }

                    Text("↵")
                        .font(.system(size: 12))
                        .foregroundColor(textDimmed)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Button {
                    manualPortText = ""
                    showManualPort = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundColor(textDimmed)
                        Text("Connect to port…")
                            .font(.system(size: 12))
                            .foregroundColor(textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var setupMCPRow: some View {
        Button {
            state.close()
            onSetupMCP?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundColor(textDimmed)
                Text("Setup MCP")
                    .font(.system(size: 12))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitManualPort() {
        let trimmed = manualPortText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), port >= 1, port <= 65535 else { return }
        state.close()
        onConnectToPort?(port)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(textDimmed)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

// MARK: - Recent row with hover × button

private struct RecentRowView: View {
    let saved: CanvasState
    let textMuted: Color
    let textDimmed: Color
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(textDimmed)
                    .frame(width: 7, height: 7)

                Text(saved.projectName)
                    .font(.system(size: 13))
                    .foregroundColor(textMuted)
                    .lineLimit(1)

                Spacer()

                if isHovered {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(textMuted)
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("\(saved.routes.count) routes")
                        .font(.system(size: 11))
                        .foregroundColor(textDimmed)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
