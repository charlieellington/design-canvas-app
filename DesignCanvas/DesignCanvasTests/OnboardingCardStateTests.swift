// Unit tests for the v3 OnboardingCardState reducer. The reducer has no timers of its own
// (the only timer — the 90s "still waiting?" hint — lives inside PasteModal), so these
// tests are straight state-transition assertions.
// See documentation/onboarding-v3-implementation.md § 8.

import XCTest
@testable import DesignCanvas

@MainActor
final class OnboardingCardStateTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "onboardingWelcomeBoxShown")
    }

    // MARK: - Base phase transitions

    func test_showDemoPanel_setsBasePhase() {
        let state = OnboardingCardState()
        state.send(.showDemoPanel)
        XCTAssertEqual(state.basePhase, .demoPanel)
    }

    func test_showDevServerWelcome_setsBasePhase() {
        let state = OnboardingCardState()
        state.send(.showDevServerWelcome)
        XCTAssertEqual(state.basePhase, .devServerWelcome)
    }

    func test_markHidden_setsHidden_withoutClosingModal() {
        let state = OnboardingCardState()
        state.send(.showDemoPanel)
        state.send(.openPasteModal(source: .demoPanel, hasLiveRoutes: false))
        XCTAssertTrue(state.isPasteModalPresented)
        state.send(.markHidden)
        XCTAssertEqual(state.basePhase, .hidden)
        XCTAssertTrue(state.isPasteModalPresented, "markHidden must leave modal open")
    }

    // MARK: - Paste modal open / close

    func test_openPasteModal_fromDemoPanel_setsPendingAutoConnect() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .demoPanel, hasLiveRoutes: false))
        XCTAssertTrue(state.isPasteModalPresented)
        XCTAssertEqual(state.pasteModalSource, .demoPanel)
        XCTAssertTrue(state.pendingDemoAutoConnect)
        XCTAssertFalse(state.didCompleteSuccessfully)
    }

    func test_openPasteModal_fromDevServerWelcome_hasLiveRoutes_mcpActivityAloneCompletes() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .devServerWelcome, hasLiveRoutes: true))
        XCTAssertFalse(state.pendingDemoAutoConnect)

        state.send(.mcpActivityDetected)
        XCTAssertFalse(state.isPasteModalPresented)
        XCTAssertTrue(state.didCompleteSuccessfully)
    }

    func test_openPasteModal_fromKeyboard_mcpActivityWaitsForRoutes() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .keyboardShortcut, hasLiveRoutes: false))

        state.send(.mcpActivityDetected)
        XCTAssertTrue(state.isPasteModalPresented, "MCP activity alone must NOT complete")
        XCTAssertFalse(state.didCompleteSuccessfully)

        state.send(.routesBecameLive)
        XCTAssertFalse(state.isPasteModalPresented)
        XCTAssertTrue(state.didCompleteSuccessfully)
    }

    func test_routesBecameLive_completesWithoutMCPActivity() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .keyboardShortcut, hasLiveRoutes: false))

        state.send(.routesBecameLive)
        XCTAssertFalse(state.isPasteModalPresented)
        XCTAssertTrue(state.didCompleteSuccessfully)

        // A late MCP signal cannot reopen a completed modal.
        state.send(.mcpActivityDetected)
        XCTAssertFalse(state.isPasteModalPresented)
        XCTAssertTrue(state.didCompleteSuccessfully)
    }

    func test_closePasteModal_userDismiss_clearsPendingDemoAutoConnect() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .demoPanel, hasLiveRoutes: false))
        XCTAssertTrue(state.pendingDemoAutoConnect)

        state.send(.closePasteModal)
        XCTAssertFalse(state.isPasteModalPresented)
        XCTAssertFalse(state.pendingDemoAutoConnect)
        XCTAssertFalse(state.didCompleteSuccessfully)
    }

    func test_mcpActivityDetected_whenModalNotPresented_isNoOp() {
        let state = OnboardingCardState()
        state.send(.mcpActivityDetected)
        XCTAssertFalse(state.didCompleteSuccessfully)
    }

    func test_routesBecameLive_whenModalNotPresented_isNoOp() {
        let state = OnboardingCardState()
        state.send(.routesBecameLive)
        XCTAssertFalse(state.didCompleteSuccessfully)
    }

    // MARK: - Reopen interactions

    func test_keyboardOpenedModal_fromHidden_closesBackToHidden() {
        let state = OnboardingCardState()
        state.send(.markHidden)
        state.send(.openPasteModal(source: .keyboardShortcut, hasLiveRoutes: false))
        state.send(.closePasteModal)
        XCTAssertEqual(state.basePhase, .hidden)
    }

    func test_keyboardOpenedModal_fromDismissed_closesBackToDismissed() {
        let state = OnboardingCardState()
        state.send(.showDevServerWelcome)
        state.send(.tapCloseWelcome)
        XCTAssertEqual(state.basePhase, .dismissed)
        state.send(.openPasteModal(source: .keyboardShortcut, hasLiveRoutes: true))
        state.send(.closePasteModal)
        XCTAssertEqual(state.basePhase, .dismissed)
    }

    // MARK: - Welcome persistence

    func test_tapCloseWelcome_persistsFlagAndSetsDismissed() {
        let state = OnboardingCardState()
        state.send(.showDevServerWelcome)
        state.send(.tapCloseWelcome)
        XCTAssertEqual(state.basePhase, .dismissed)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "onboardingWelcomeBoxShown"))
    }

    // MARK: - Demo auto-connect flag

    func test_clearPendingDemoAutoConnect_clears() {
        let state = OnboardingCardState()
        state.send(.openPasteModal(source: .demoPanel, hasLiveRoutes: false))
        XCTAssertTrue(state.pendingDemoAutoConnect)
        state.send(.clearPendingDemoAutoConnect)
        XCTAssertFalse(state.pendingDemoAutoConnect)
    }

    // MARK: - Dev server status integration

    func test_devServerRunning_fromDemoPanel_setsHidden_doesNotCloseModal() {
        let state = OnboardingCardState()
        state.send(.showDemoPanel)
        state.send(.openPasteModal(source: .demoPanel, hasLiveRoutes: false))
        state.send(.devServerStatusChanged(running: true, port: 3000))
        XCTAssertEqual(state.basePhase, .hidden)
        XCTAssertTrue(state.isPasteModalPresented, "modal presentation is orthogonal to base phase")
    }

    func test_devServerRunning_fromDevServerWelcome_setsHidden() {
        let state = OnboardingCardState()
        state.send(.showDevServerWelcome)
        state.send(.devServerStatusChanged(running: true, port: 3000))
        XCTAssertEqual(state.basePhase, .hidden)
    }

    func test_devServerNotRunning_doesNotChangeBasePhase() {
        let state = OnboardingCardState()
        state.send(.showDemoPanel)
        state.send(.devServerStatusChanged(running: false, port: nil))
        XCTAssertEqual(state.basePhase, .demoPanel)
    }

    // MARK: - Paste string

    func test_pasteStringConstant_matchesExpected() {
        // Byte-exact guard. Update in lockstep with OnboardingPasteString.swift.
        let expected = """
        Set up Design Canvas for this project. Do these steps in order:

        1. Install the MCP server. Run:
           claude mcp add design-canvas -s user -- npx -y design-canvas-mcp

        2. Start the dev server. Check package.json for the dev command (usually npm run dev, pnpm dev, etc). If you're not sure which command to use, ask me — never guess. Start it so it keeps running.

        3. After both succeed, tell me:
           "Done! MCP installed and dev server running.
           To finish setup, close this session and reopen.
           Then paste this as your first message:"

           And give me this exact prompt to copy:
           Show me what's on my Design Canvas

        If the install command errors (e.g. on Cursor or another agent), use the fallback:
        - Cursor: add {"design-canvas":{"command":"npx","args":["-y","design-canvas-mcp"]}} to .cursor/mcp.json
        - Other agents: run `npx -y design-canvas-mcp install`

        Edge cases (no package.json, port conflict, missing node) — ask me, never guess.
        """
        XCTAssertEqual(OnboardingPasteString.official, expected)
    }

    func test_localBuildPasteUsesSourceAdapterAndIsolatedProfile() {
        XCTAssertFalse(BuildPolicy.isOfficialDistribution)
        XCTAssertEqual(OnboardingPasteString.current, OnboardingPasteString.local)
        XCTAssertTrue(OnboardingPasteString.current.contains("mcp-server/dist/index.js"))
        XCTAssertTrue(OnboardingPasteString.current.contains("DESIGN_CANVAS_PROFILE=local"))
        XCTAssertTrue(OnboardingPasteString.current.contains("DESIGN_CANVAS_URL=\(BuildPolicy.localAPIURL)"))
        XCTAssertFalse(OnboardingPasteString.current.contains("npx -y design-canvas-mcp"))
    }
}
