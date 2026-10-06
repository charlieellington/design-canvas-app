// Unit tests for MCPActivityDetector — the 500 ms debounce rule and the single-shot
// behaviour that together keep the paste modal from auto-closing on stale background
// traffic. See onboarding-v3-implementation.md § 8.

import XCTest
@testable import DesignCanvas

@MainActor
final class MCPActivityDetectorTests: XCTestCase {

    private func makeDetector() -> (MCPActivityDetector, () -> Int) {
        let detector = MCPActivityDetector()
        var fires = 0
        detector.onFirstListRoutes = { fires += 1 }
        return (detector, { fires })
    }

    // MARK: - Arm / debounce

    func test_armThenImmediateNote_isDebounced_andDoesNotFire() {
        let (detector, fires) = makeDetector()
        detector.arm()
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 0)
        XCTAssertTrue(detector.isArmed, "still armed after a debounced note")
    }

    func test_armThenWaitThenNote_firesOnce() async {
        let (detector, fires) = makeDetector()
        detector.arm()
        try? await Task.sleep(nanoseconds: 600_000_000)
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 1)
        XCTAssertFalse(detector.isArmed)
    }

    func test_secondNoteAfterFire_isNoOp() async {
        let (detector, fires) = makeDetector()
        detector.arm()
        try? await Task.sleep(nanoseconds: 600_000_000)
        detector.noteListRoutes()
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 1)
    }

    // MARK: - Gating

    func test_noteBeforeArm_isNoOp() {
        let (detector, fires) = makeDetector()
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 0)
    }

    func test_disarmAfterArm_blocksNextFire() async {
        let (detector, fires) = makeDetector()
        detector.arm()
        try? await Task.sleep(nanoseconds: 600_000_000)
        detector.disarm()
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 0)
    }

    func test_reArmAfterCompletion_canFireAgain() async {
        let (detector, fires) = makeDetector()
        detector.arm()
        try? await Task.sleep(nanoseconds: 600_000_000)
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 1)

        detector.arm()
        try? await Task.sleep(nanoseconds: 600_000_000)
        detector.noteListRoutes()
        XCTAssertEqual(fires(), 2)
    }
}
