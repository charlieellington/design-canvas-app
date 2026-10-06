// Decoder coverage for /api/organizations/{uuid}/usage. The endpoint is
// unofficial, so the contract is "best-effort defensive" — these fixtures
// pin the three states the pill must survive: dormant session, active
// session, and a true Free-tier response.

import XCTest
@testable import DesignCanvas

final class ClaudeUsageDecoderTests: XCTestCase {
    private let captured = Date(timeIntervalSince1970: 1_716_000_000)

    /// Verbatim live response (Max 20x, between sessions, 2026-05-21). `null`
    /// `resets_at` used to make `decode` return nil — and the pill vanish.
    func testDormantSession_returnsSnapshotAndFallsBackToWeeklyDisplay() throws {
        let json: [String: Any] = [
            "five_hour": ["utilization": 0.0, "resets_at": NSNull()],
            "seven_day": ["utilization": 23.0, "resets_at": "2026-05-24T17:00:00.553589+00:00"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": ["utilization": 0.0, "resets_at": NSNull()],
            "extra_usage": ["is_enabled": false]
        ]
        let snap = try XCTUnwrap(UsageDecoder.decode(json: json, capturedAt: captured))
        XCTAssertEqual(snap.fiveHourPct, 0.0)
        XCTAssertNil(snap.fiveHourResetsAt)
        XCTAssertEqual(snap.sevenDayPct, 23.0)
        XCTAssertNotNil(snap.sevenDayResetsAt)
        XCTAssertEqual(snap.displayMode, .weekly)
        XCTAssertEqual(snap.displayPct, 23.0)
        XCTAssertEqual(snap.displayResetsAt, snap.sevenDayResetsAt)
    }

    func testActiveSession_prefersSessionDisplay() throws {
        let json: [String: Any] = [
            "five_hour": ["utilization": 67.0, "resets_at": "2026-05-21T16:00:00.000000+00:00"],
            "seven_day": ["utilization": 23.0, "resets_at": "2026-05-24T17:00:00.000000+00:00"]
        ]
        let snap = try XCTUnwrap(UsageDecoder.decode(json: json, capturedAt: captured))
        XCTAssertEqual(snap.displayMode, .session)
        XCTAssertEqual(snap.displayPct, 67.0)
        XCTAssertEqual(snap.displayResetsAt, snap.fiveHourResetsAt)
        XCTAssertNotNil(snap.elapsedFraction(now: captured))
    }

    func testFreeTier_returnsNil() {
        // No five_hour block at all.
        XCTAssertNil(UsageDecoder.decode(json: [:], capturedAt: captured))
        // Block present but utilization is null — also Free tier.
        let json: [String: Any] = [
            "five_hour": ["utilization": NSNull(), "resets_at": NSNull()]
        ]
        XCTAssertNil(UsageDecoder.decode(json: json, capturedAt: captured))
    }

    func testDormantSessionWithZeroWeekly_staysInSessionMode() throws {
        // Brand-new account: no session window AND no weekly usage yet. The
        // pill should still render — as 0% session — rather than try to fall
        // back to a meaningless weekly bar.
        let json: [String: Any] = [
            "five_hour": ["utilization": 0.0, "resets_at": NSNull()],
            "seven_day": ["utilization": 0.0, "resets_at": "2026-05-24T17:00:00.000000+00:00"]
        ]
        let snap = try XCTUnwrap(UsageDecoder.decode(json: json, capturedAt: captured))
        XCTAssertEqual(snap.displayMode, .session)
        XCTAssertEqual(snap.displayPct, 0.0)
        XCTAssertNil(snap.displayResetsAt)
    }
}

final class ClaudeMenuBarFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_716_000_000)

    func testCompactAccountLabels_onlyAppearWhenRequested() {
        XCTAssertEqual(
            ClaudeMenuBarFormatter.accountPrefix(label: ClaudeAccountsManager.primaryLabel, isVisible: true),
            "M "
        )
        XCTAssertEqual(
            ClaudeMenuBarFormatter.accountPrefix(label: ClaudeAccountsManager.secondLabel, isVisible: true),
            "2 "
        )
        XCTAssertEqual(
            ClaudeMenuBarFormatter.accountPrefix(label: ClaudeAccountsManager.primaryLabel, isVisible: false),
            ""
        )
    }

    func testSessionCountdown_usesMinutesBelowOneHour() {
        let snapshot = makeSnapshot(
            fiveHourPct: 32,
            fiveHourReset: now.addingTimeInterval(42 * 60)
        )

        XCTAssertEqual(ClaudeMenuBarFormatter.usageText(for: snapshot, now: now), "32% · 42m")
    }

    func testSessionCountdown_dropsMinutesAboveOneHour() {
        let snapshot = makeSnapshot(
            fiveHourPct: 32,
            fiveHourReset: now.addingTimeInterval(2 * 60 * 60 + 59 * 60)
        )

        XCTAssertEqual(ClaudeMenuBarFormatter.usageText(for: snapshot, now: now), "32% · 2h")
    }

    func testWeeklyFallback_dropsHoursAndWeeklySuffix() {
        let snapshot = makeSnapshot(
            fiveHourPct: 0,
            sevenDayPct: 64,
            sevenDayReset: now.addingTimeInterval((4 * 24 + 23) * 60 * 60)
        )

        XCTAssertEqual(ClaudeMenuBarFormatter.usageText(for: snapshot, now: now), "64% · 4d")
    }

    func testMissingReset_showsPercentageOnly() {
        let snapshot = makeSnapshot(fiveHourPct: 5)

        XCTAssertEqual(ClaudeMenuBarFormatter.usageText(for: snapshot, now: now), "5%")
    }

    private func makeSnapshot(
        fiveHourPct: Double,
        fiveHourReset: Date? = nil,
        sevenDayPct: Double? = nil,
        sevenDayReset: Date? = nil
    ) -> ClaudeUsageService.Snapshot {
        ClaudeUsageService.Snapshot(
            fiveHourPct: fiveHourPct,
            fiveHourResetsAt: fiveHourReset,
            sevenDayPct: sevenDayPct,
            sevenDayResetsAt: sevenDayReset,
            sevenDayOpusPct: nil,
            sevenDaySonnetPct: nil,
            capturedAt: now
        )
    }
}
