// Observable state for the workspace switcher panel. Combines running servers (from PortScanner)
// with saved sessions (from SessionPersistence) into a unified list the UI can render.

import Foundation
import Observation

@Observable
@MainActor
class WorkspaceSwitcherState {

    var isOpen = false
    var searchText = ""

    /// Current active port — used to show checkmark on the active workspace.
    var activePort: Int = 3000

    /// Bumped after deleting a recent — forces computed properties to re-evaluate.
    private var refreshTrigger = 0

    weak var portScanner: PortScanner?
    weak var sessionPersistence: SessionPersistence?

    // MARK: - Computed lists

    /// Running servers that match the search query.
    var filteredRunning: [DetectedServer] {
        guard let scanner = portScanner else { return [] }
        let servers = scanner.detectedServers
        guard !searchText.isEmpty else { return servers }
        let query = searchText.lowercased()
        return servers.filter {
            $0.projectName.lowercased().contains(query) || "\($0.port)".contains(query)
        }
    }

    /// Saved sessions not currently running, matching the search query.
    /// Deduplicates against Running by both projectDir and projectName to handle
    /// path mismatches (trailing slashes, symlinks) and port changes.
    var filteredRecent: [CanvasState] {
        _ = refreshTrigger  // Observe changes after delete
        guard let persistence = sessionPersistence else { return [] }
        let all = persistence.listAll()
        let running = portScanner?.detectedServers ?? []
        let runningDirs = Set(running.compactMap(\.projectDir))
        let runningNames = Set(running.map { $0.projectName.lowercased() })
        let offlineAll = all.filter {
            !runningDirs.contains($0.projectDir)
            && !runningNames.contains($0.projectName.lowercased())
        }
        // Deduplicate by project name — keep the most recent (first in list, sorted by date)
        var seenNames = Set<String>()
        let offline = offlineAll.filter { seenNames.insert($0.projectName.lowercased()).inserted }
        guard !searchText.isEmpty else { return offline }
        let query = searchText.lowercased()
        return offline.filter {
            $0.projectName.lowercased().contains(query)
        }
    }

    /// Look up saved route count for a running server (by projectDir match).
    func savedRouteCount(for server: DetectedServer) -> Int? {
        guard let persistence = sessionPersistence, let dir = server.projectDir else { return nil }
        guard let saved = persistence.load(projectDir: dir) else { return nil }
        return saved.routes.isEmpty ? nil : saved.routes.count
    }

    // MARK: - Actions

    func open() {
        searchText = ""
        isOpen = true
        portScanner?.scan()
    }

    func close() {
        isOpen = false
        searchText = ""
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Delete a saved session and refresh the list.
    func deleteRecent(projectDir: String) {
        sessionPersistence?.delete(projectDir: projectDir)
        refreshTrigger += 1
    }

    /// Find the live port for a saved project by matching projectDir against running servers.
    /// Returns nil if the project isn't currently running.
    func resolvePort(for saved: CanvasState) -> Int? {
        portScanner?.detectedServers.first { $0.projectDir == saved.projectDir }?.port
    }
}
