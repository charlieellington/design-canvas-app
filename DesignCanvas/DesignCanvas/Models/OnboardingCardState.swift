// Onboarding state for the v3 paste-modal flow. Separates base phase (demo panel /
// welcome box / hidden / dismissed) from modal presentation so user-initiated dismiss
// and underlying phase stay orthogonal. See documentation/onboarding-v3-implementation.md § 3.

import Foundation
import Observation

@Observable
@MainActor
final class OnboardingCardState {

    // MARK: - Types

    enum BasePhase: Equatable {
        case hidden              // share-link, returning user, post-welcome
        case demoPanel
        case devServerWelcome    // first live launch, flag unset
        case dismissed           // welcome explicitly closed
    }

    enum ModalSource: Equatable {
        case demoPanel
        case devServerWelcome
        case keyboardShortcut
    }

    enum Event {
        case showDemoPanel
        case showDevServerWelcome
        case markHidden
        case openPasteModal(source: ModalSource, hasLiveRoutes: Bool)
        case closePasteModal
        case mcpActivityDetected               // list_routes reached DC post-arm
        case routesBecameLive                  // document.routes.count transitioned 0 → N
        case copyPasteString
        case clearPendingDemoAutoConnect
        case tapCloseWelcome
        case devServerStatusChanged(running: Bool, port: Int?)
    }

    // MARK: - Observable state

    private(set) var basePhase: BasePhase = .hidden
    private(set) var isPasteModalPresented = false
    private(set) var pasteModalSource: ModalSource?
    private(set) var pendingDemoAutoConnect = false
    private(set) var didCompleteSuccessfully = false

    // MARK: - Internals

    // Session-only success gates. Reset on every .openPasteModal.
    private var sawMCPActivity = false
    private var sawRoutesLive = false

    private enum Keys {
        static let welcomeBoxShown = "onboardingWelcomeBoxShown"
    }

    // MARK: - Reducer

    func send(_ event: Event) {
        switch event {

        case .showDemoPanel:
            basePhase = .demoPanel

        case .showDevServerWelcome:
            basePhase = .devServerWelcome

        case .markHidden:
            basePhase = .hidden

        case .openPasteModal(let source, let hasLiveRoutes):
            isPasteModalPresented = true
            pasteModalSource = source
            didCompleteSuccessfully = false
            sawMCPActivity = false
            sawRoutesLive = hasLiveRoutes
            pendingDemoAutoConnect = (source == .demoPanel)
            AnalyticsService.shared.capture(.pasteModalOpened, properties: [
                "source": String(describing: source),
                "has_live_routes": hasLiveRoutes,
            ])

        case .closePasteModal:
            isPasteModalPresented = false
            pasteModalSource = nil
            pendingDemoAutoConnect = false
            sawMCPActivity = false
            sawRoutesLive = false

        case .mcpActivityDetected:
            guard isPasteModalPresented else { return }
            sawMCPActivity = true
            if sawRoutesLive { completeModal() }

        case .routesBecameLive:
            guard isPasteModalPresented else { return }
            sawRoutesLive = true
            completeModal()

        case .copyPasteString:
            AnalyticsService.shared.capture(.pasteModalCopied, properties: [
                "source": pasteModalSource.map { String(describing: $0) } ?? "unknown",
            ])

        case .clearPendingDemoAutoConnect:
            pendingDemoAutoConnect = false

        case .tapCloseWelcome:
            basePhase = .dismissed
            UserDefaults.standard.set(true, forKey: Keys.welcomeBoxShown)

        case .devServerStatusChanged(let running, _):
            if running {
                switch basePhase {
                case .demoPanel, .devServerWelcome:
                    basePhase = .hidden
                default:
                    break
                }
            }
        }
    }

    // MARK: - Internal

    private func completeModal() {
        didCompleteSuccessfully = true
        isPasteModalPresented = false
        pasteModalSource = nil
        // Keep pendingDemoAutoConnect — demo→live handoff may still be in flight
        // if completion fired from the Peter path with demo session still active.
        sawMCPActivity = false
        sawRoutesLive = false
    }
}
