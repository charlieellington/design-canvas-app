// MCP setup sheet — helps users discover and install the MCP server in their AI client.
// Tabbed per client (Claude Code, Cursor, VS Code, Windsurf) with copy buttons and deeplinks.
// Shows live connection indicator that flips to success state when an MCP client connects.

import SwiftUI

struct MCPSetupSheet: View {
    @Bindable var state: MCPConnectionState

    @State private var selectedTab = 0
    @State private var copiedSnippet: String?

    // Design tokens (matching CommandPalette)
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))
    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))
    private let codeBg = Color(nsColor: NSColor(red: 0x14/255, green: 0x15/255, blue: 0x17/255, alpha: 1))

    private let tabs = ["Claude Code", "Cursor", "VS Code", "Windsurf"]

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            // Panel
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                divider

                if state.isConnected {
                    successSection
                } else {
                    tabBar
                    divider
                    tabContent
                    divider
                    connectionIndicator
                }
            }
            .frame(width: 520)
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
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect via MCP")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textPrimary)
            capabilityCards
        }
        .padding(20)
    }

    // MARK: - Capability Cards

    private var capabilityCards: some View {
        HStack(spacing: 8) {
            capabilityCard(icon: "rectangle.stack", label: "List routes", endpoint: "GET /routes")
            capabilityCard(icon: "plus.rectangle.on.rectangle", label: "Add routes", endpoint: "POST /routes")
            capabilityCard(icon: "trash", label: "Remove routes", endpoint: "DELETE /routes")
            capabilityCard(icon: "camera.viewfinder", label: "Capture canvas", endpoint: "POST /capture")
        }
    }

    private func capabilityCard(icon: String, label: String, endpoint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(accent)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textPrimary)
            Text(endpoint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textDimmed)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border, lineWidth: 1)
                )
        )
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, label in
                Button {
                    selectedTab = index
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selectedTab == index ? .medium : .regular))
                        .foregroundColor(selectedTab == index ? textPrimary : textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == index
                                ? Color.white.opacity(0.06)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if BuildPolicy.isOfficialDistribution {
                    switch selectedTab {
                    case 0: claudeCodeTab
                    case 1: cursorTab
                    case 2: vsCodeTab
                    case 3: windsurfTab
                    default: claudeCodeTab
                    }
                } else {
                    localSourceTab
                }

                Text("Requires Node.js 20.9+")
                    .font(.system(size: 11))
                    .foregroundColor(textDimmed)
            }
            .padding(16)
        }
        .frame(maxHeight: 260)
    }

    private var localSourceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build the MCP adapter from this app's source checkout: run npm ci and npm run build in mcp-server. Replace the path below with its absolute dist/index.js path.")
                .font(.system(size: 13))
                .foregroundColor(textMuted)
                .fixedSize(horizontal: false, vertical: true)
            codeBlock(
                """
                {
                  "\(selectedTab == 2 ? "servers" : "mcpServers")": {
                    "design-canvas": {
                      "command": "node",
                      "args": ["/absolute/path/to/design-canvas-app/mcp-server/dist/index.js"],
                      "env": {
                        "DESIGN_CANVAS_PROFILE": "local",
                        "DESIGN_CANVAS_URL": "\(BuildPolicy.localAPIURL)"
                      }
                    }
                  }
                }
                """,
                id: "local-source"
            )
            Text(localConfigLocation)
                .font(.system(size: 11))
                .foregroundColor(textDimmed)
            Link("Source MCP setup instructions", destination: URL(string: "https://github.com/charlieellington/design-canvas-app/blob/main/docs/MCP.md")!)
                .font(.system(size: 12))
            reloadNote
        }
    }

    private var localConfigLocation: String {
        switch selectedTab {
        case 1: return "Add to .cursor/mcp.json"
        case 2: return "Add to .vscode/mcp.json"
        case 3: return "Add to ~/.codeium/windsurf/mcp_config.json"
        default: return "Add to .mcp.json in your project root"
        }
    }

    // MARK: - Claude Code Tab

    private var claudeCodeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run in your terminal:")
                .font(.system(size: 13))
                .foregroundColor(textMuted)

            codeBlock(
                "claude mcp add design-canvas -s user -- npx -y design-canvas-mcp",
                id: "claude"
            )

            manualSetupDisclosure(
                json: """
                {
                  "mcpServers": {
                    "design-canvas": {
                      "command": "npx",
                      "args": ["-y", "design-canvas-mcp"]
                    }
                  }
                }
                """,
                note: "Add to .mcp.json in your project root",
                id: "claude-json"
            )
        }
    }

    // MARK: - Cursor Tab

    private var cursorTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            deeplinkButton(
                label: "Add to Cursor",
                url: "cursor://anysphere.cursor-deeplink/mcp/install?name=design-canvas&config=eyJjb21tYW5kIjoibnB4IiwiYXJncyI6WyIteSIsImRlc2lnbi1jYW52YXMtbWNwIl19"
            )

            manualSetupDisclosure(
                json: """
                {
                  "mcpServers": {
                    "design-canvas": {
                      "command": "npx",
                      "args": ["-y", "design-canvas-mcp"]
                    }
                  }
                }
                """,
                note: "Add to .cursor/mcp.json",
                id: "cursor-json"
            )

            reloadNote
        }
    }

    // MARK: - VS Code Tab

    private var vsCodeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            deeplinkButton(
                label: "Add to VS Code",
                url: "vscode:mcp/install?%7B%22name%22%3A%22design-canvas%22%2C%22command%22%3A%22npx%22%2C%22args%22%3A%5B%22-y%22%2C%22design-canvas-mcp%22%5D%7D"
            )

            manualSetupDisclosure(
                json: """
                {
                  "servers": {
                    "design-canvas": {
                      "command": "npx",
                      "args": ["-y", "design-canvas-mcp"]
                    }
                  }
                }
                """,
                note: "Add to .vscode/mcp.json — note: root key is \"servers\", not \"mcpServers\"",
                id: "vscode-json"
            )

            reloadNote
        }
    }

    // MARK: - Windsurf Tab

    private var windsurfTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to ~/.codeium/windsurf/mcp_config.json:")
                .font(.system(size: 13))
                .foregroundColor(textMuted)

            codeBlock(
                """
                {
                  "mcpServers": {
                    "design-canvas": {
                      "command": "npx",
                      "args": ["-y", "design-canvas-mcp"]
                    }
                  }
                }
                """,
                id: "windsurf"
            )

            reloadNote
        }
    }

    // MARK: - Connection Indicator

    private var connectionIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(textDimmed)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)
                .animation(
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                    value: pulseOpacity
                )
            Text("Waiting for connection...")
                .font(.system(size: 12))
                .foregroundColor(textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Pulse between 0.4 and 1.0 opacity — driven by the view lifecycle.
    private var pulseOpacity: Double { 0.4 }

    // MARK: - Success Section

    private var successSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(textPrimary)
            }

            Text("Example prompts")
                .font(.system(size: 13))
                .foregroundColor(textMuted)

            VStack(alignment: .leading, spacing: 6) {
                promptCard(icon: "plus.rectangle.on.rectangle", text: "Use the design-canvas MCP to add /dashboard to the canvas", id: "prompt-add")
                promptCard(icon: "rectangle.stack", text: "Use the design-canvas MCP to show me the routes on the canvas", id: "prompt-list")
                promptCard(icon: "camera.viewfinder", text: "Use design-canvas to capture the canvas so you can see my app", id: "prompt-capture")
                promptCard(icon: "arrow.left.arrow.right", text: "Add /pricing at desktop (1280) and mobile (375) side by side", id: "prompt-responsive")
                promptCard(icon: "trash", text: "Remove the mobile version of /settings from the canvas", id: "prompt-remove")
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(textDimmed)
                Text("Adding 8+ routes at once may take a while — agents should inform you before bulk-loading.")
                    .font(.system(size: 11))
                    .foregroundColor(textDimmed)
            }
            .padding(.top, 2)

            HStack {
                Spacer()
                Button {
                    state.close()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    // MARK: - Reusable Components

    private func codeBlock(_ code: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyToClipboard(code, id: id)
            } label: {
                Text(copiedSnippet == id ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(copiedSnippet == id ? accent : textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(codeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border, lineWidth: 1)
                )
        )
    }

    private func deeplinkButton(label: String, url: String) -> some View {
        Button {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func manualSetupDisclosure(json: String, note: String, id: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(textDimmed)
                codeBlock(json, id: id)
            }
            .padding(.top, 8)
        } label: {
            Text("Manual setup")
                .font(.system(size: 12))
                .foregroundColor(textMuted)
        }
        .tint(textMuted)
    }

    private func promptCard(icon: String, text: String, id: String) -> some View {
        Button {
            copyToClipboard(text, id: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textDimmed)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(textMuted)
                Spacer()
                Image(systemName: copiedSnippet == id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(copiedSnippet == id ? accent : textDimmed)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(codeBg)
            )
        }
        .buttonStyle(.plain)
    }

    private var reloadNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
            Text("Reload your editor after saving the config.")
                .font(.system(size: 11))
        }
        .foregroundColor(textDimmed)
    }

    private var divider: some View {
        Rectangle()
            .fill(border)
            .frame(height: 1)
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSnippet = id
        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedSnippet == id {
                copiedSnippet = nil
            }
        }
    }
}

// MARK: - MCP Nudge Toast

struct MCPNudgeToast: View {
    let mcpState: MCPConnectionState

    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))

    var body: some View {
        HStack(spacing: 12) {
            Button {
                mcpState.open()
                mcpState.isNudgeVisible = false
            } label: {
                Text("Add routes via MCP → ")
                    .font(.system(size: 13))
                    .foregroundColor(textMuted)
                + Text("Connect")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textPrimary)
            }
            .buttonStyle(.plain)

            Button {
                mcpState.isNudgeVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(surface)
                .overlay(
                    Capsule()
                        .strokeBorder(border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
        )
    }
}
