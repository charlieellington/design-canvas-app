// Shows a persistent hint about double-clicking to interact with frame content.
// Triggered when the user scrolls over a frame (canvas pans instead of page scrolling).
// Stays visible with a dismiss button until closed or until the user double-clicks a frame.
// Suppresses permanently once the user has double-clicked into any frame.

import Foundation
import Observation

@Observable
class InteractHintCoordinator {

    // MARK: - Public state (read by SwiftUI toast)

    var isVisible: Bool = false

    // MARK: - Private tracking

    private var scrollCount = 0
    private var scrollWindowStart: Date?

    // MARK: - Persistence

    private static let userKnowsKey = "interactHint.userKnows"

    private var userKnowsShortcut: Bool {
        get { UserDefaults.standard.bool(forKey: Self.userKnowsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.userKnowsKey) }
    }

    // MARK: - Scroll recording

    /// Called from InteractionOverlay on every scroll event over a frame (default mode only).
    func recordScroll() {
        guard !userKnowsShortcut, !isVisible else { return }

        let now = Date()

        // Reset window if more than 1 second since first scroll
        if let start = scrollWindowStart, now.timeIntervalSince(start) > 1.0 {
            resetScrollWindow()
        }

        if scrollWindowStart == nil {
            scrollWindowStart = now
        }

        scrollCount += 1

        if scrollCount >= 3 {
            isVisible = true
            resetScrollWindow()
        }
    }

    /// Called when user double-clicks into a frame — they know the shortcut, never show again.
    func markUserKnows() {
        userKnowsShortcut = true
        isVisible = false
    }

    /// Dismiss the hint (called by the dismiss button).
    func dismiss() {
        isVisible = false
    }

    private func resetScrollWindow() {
        scrollCount = 0
        scrollWindowStart = nil
    }
}
