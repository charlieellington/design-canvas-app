// Tracks MCP connection status and controls the MCP setup sheet.
// Connection detected two ways: (1) scanning config files on startup for "design-canvas",
// (2) monitoring HTTP API requests from external MCP clients at runtime.

import Foundation
import Observation

@Observable
@MainActor
class MCPConnectionState {

    var isSheetOpen = false
    var lastAPIRequestTime: Date?
    var isNudgeVisible = false

    /// True if MCP is configured in any known AI client config, or an API request was seen.
    var isConfigured = false

    /// True if an MCP client has actually hit the API this session.
    var hasConnectedThisSession = false

    /// Configured OR actively connected — either means the user has set up MCP.
    var isConnected: Bool { isConfigured || hasConnectedThisSession }

    /// Whether the delayed nudge toast has already been shown (persisted across launches).
    var hasShownNudge: Bool {
        get { UserDefaults.standard.bool(forKey: "mcpNudgeShown") }
        set { UserDefaults.standard.set(newValue, forKey: "mcpNudgeShown") }
    }

    // MARK: - Actions

    func open() { isSheetOpen = true }
    func close() { isSheetOpen = false }

    func recordAPIRequest() {
        lastAPIRequestTime = Date()
        if !hasConnectedThisSession {
            hasConnectedThisSession = true
        }
    }

    /// Check common AI client config files for "design-canvas" MCP server entry.
    /// Called once on app startup. Runs on a background thread to avoid blocking launch.
    func checkInstalledConfigs() {
        Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let configPaths = [
                "\(home)/.claude.json",                                    // Claude Code
                "\(home)/.cursor/mcp.json",                                // Cursor (global)
                "\(home)/.codeium/windsurf/mcp_config.json",               // Windsurf
            ]

            let found = configPaths.contains { path in
                guard let data = FileManager.default.contents(atPath: path),
                      let text = String(data: data, encoding: .utf8) else { return false }
                return text.contains("design-canvas")
            }

            if found {
                await MainActor.run { self.isConfigured = true }
            }
        }
    }
}
