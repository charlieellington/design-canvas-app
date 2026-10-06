// Single-shot detector for the first list_routes call after the paste modal opens. Scoped
// to list_routes only (the paste prompt tells the agent to call it first) with a 500 ms
// post-arm debounce so stale traffic from a returning agent doesn't auto-close the modal
// the instant it appears. See onboarding-v3-implementation.md § 4.

import Foundation
import Observation

@Observable
@MainActor
final class MCPActivityDetector {
    private(set) var isArmed: Bool = false
    private var armedAt: Date?
    var onFirstListRoutes: (() -> Void)?

    private static let debounce: TimeInterval = 0.5

    /// Call when the paste modal appears.
    func arm() {
        isArmed = true
        armedAt = Date()
    }

    /// Call to stop listening without firing (e.g. user dismissed the modal).
    func disarm() {
        isArmed = false
        armedAt = nil
    }

    /// Called by HTTPAPIServer ONLY on the list_routes endpoint. Ignores the first
    /// 500 ms after arm to reject stale traffic from a pre-existing agent session.
    func noteListRoutes() {
        guard isArmed, let armedAt,
              Date().timeIntervalSince(armedAt) >= Self.debounce else { return }
        isArmed = false
        self.armedAt = nil
        onFirstListRoutes?()
    }
}
