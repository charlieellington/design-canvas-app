// Detects when new dev servers appear on the network. Compares successive port scan results
// and surfaces new servers via a toast or auto-connects when the app is idle.

import Foundation
import Observation

@Observable
@MainActor
class NewServerDetector {

    /// Whether the toast is visible.
    private(set) var isVisible = false

    /// The newly detected server to show in the toast.
    private(set) var detectedServer: DetectedServer?

    /// Called when the app is disconnected and a new server appears — auto-connect instead of toasting.
    var onAutoConnect: ((DetectedServer) -> Void)?

    private var previousPorts: Set<Int> = []
    private var dismissTask: Task<Void, Never>?
    private var hasCompletedFirstScan = false

    /// Compare the latest scan results against the previous set. If new ports appeared,
    /// either show a toast (if connected) or auto-connect (if idle).
    ///
    /// C0: `activePorts` is the union of the primary server's port + every bound
    /// `ServerBinding.port`. New scans matching any of those are filtered — we already
    /// know about them.
    func processNewScan(servers: [DetectedServer], activePorts: Set<Int>, isDisconnected: Bool) {
        // Demo mode: pill handles server notification, not this detector
        guard !AppServices.shared.demo.isInDemoMode else { return }

        let currentPorts = Set(servers.map(\.port))

        // Skip the first scan — everything looks "new" on launch
        guard hasCompletedFirstScan else {
            previousPorts = currentPorts
            hasCompletedFirstScan = true
            return
        }

        let newPorts = currentPorts.subtracting(previousPorts)
        previousPorts = currentPorts

        guard !newPorts.isEmpty else { return }

        // Find the first new server that isn't already a known active port.
        guard let newServer = servers.first(where: { newPorts.contains($0.port) && !activePorts.contains($0.port) }) else {
            return
        }

        if isDisconnected {
            // Primary not running — auto-connect the new server as primary.
            FileLogger.shared.log("Auto-connecting to \(newServer.projectName) :\(newServer.port)", tag: "NewServerDetector")
            onAutoConnect?(newServer)
        } else {
            // Primary already running — surface the new server via a toast. The toast's
            // action is wired in DesignCanvasApp; in C0 it routes to "bind another port"
            // rather than "switch primary".
            show(server: newServer)
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isVisible = false
        detectedServer = nil
    }

    // MARK: - Private

    private func show(server: DetectedServer) {
        dismissTask?.cancel()
        detectedServer = server
        isVisible = true
        FileLogger.shared.log("Toast: \(server.projectName) :\(server.port)", tag: "NewServerDetector")

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            isVisible = false
            detectedServer = nil
        }
    }
}
