// Telemetry is disabled in the public source distribution.
import Foundation

final class AnalyticsService {
    static let shared = AnalyticsService()
    enum Event: String {
        case appOpened = "app_opened"
        case demoModeStarted = "demo_mode_started"
        case demoModeCompleted = "demo_mode_completed"
        case devServerConnected = "dev_server_connected"
        case routesLoaded = "routes_loaded"
        case shareCreated = "share_created"
        case exportCreated = "export_created"
        case mcpCommandReceived = "mcp_command_received"
        case mcpFirstConnection = "mcp_first_connection"
        case pasteModalOpened = "paste_modal_opened"
        case pasteModalCopied = "paste_modal_copied"
        case workspaceSwitched = "workspace_switched"
        case errorEncountered = "error_encountered"
        case stormDetected = "storm_detected"
        case stormResolved = "storm_resolved"
    }

    private init() {}
    func start() {}
    func capture(_ event: Event, properties: [String: Any]? = nil) {}
    func identify(distinctId: String, userProperties: [String: Any]? = nil) {}
    func flush() {}
    func reset() {}
}
