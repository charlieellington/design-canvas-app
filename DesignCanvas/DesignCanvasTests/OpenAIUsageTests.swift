import XCTest
@testable import DesignCanvas

final class OpenAIUsageDecoderTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_752_600_000)

    func testWeeklyOnlySnapshot_prefersCanonicalBucketAndFormatsMenuBar() throws {
        let reset = capturedAt.addingTimeInterval((6 * 24 + 23) * 60 * 60)
        let canonical = limit(
            primary: window(used: 3, duration: 10_080, reset: reset),
            credits: ["hasCredits": false, "unlimited": false, "balance": "0"],
            plan: "pro"
        )
        let spark = limit(primary: window(used: 0, duration: 10_080, reset: nil), name: "GPT-5.3-Codex-Spark")
        let response: [String: Any] = [
            "rateLimits": limit(primary: window(used: 99, duration: 300, reset: nil)),
            "rateLimitsByLimitId": [
                "codex": canonical,
                "codex_bengalfox": spark
            ]
        ]

        let snapshot = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: response,
            planType: "pro",
            capturedAt: capturedAt
        ))

        XCTAssertEqual(snapshot.displayWindow?.usedPercent, 3)
        XCTAssertEqual(snapshot.displayWindow?.remainingPercent, 97)
        XCTAssertEqual(snapshot.planDisplayName, "ChatGPT Pro")
        XCTAssertEqual(snapshot.credits?.displayBalance, "0")
        XCTAssertEqual(snapshot.additionalLimits.first?.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(snapshot.additionalLimits.first?.displayWindow?.remainingPercent, 100)
        XCTAssertEqual(
            OpenAIUsageFormatter.menuBarText(snapshot: snapshot, now: capturedAt),
            "O 3% · 6d"
        )
    }

    func testFiveHourAndWeeklySnapshot_selectsShortestWindow() throws {
        let response: [String: Any] = [
            "rateLimits": limit(
                primary: window(
                    used: 14,
                    duration: 300,
                    reset: capturedAt.addingTimeInterval(3 * 60 * 60 + 42 * 60)
                ),
                secondary: window(
                    used: 40,
                    duration: 10_080,
                    reset: capturedAt.addingTimeInterval(5 * 24 * 60 * 60)
                )
            )
        ]

        let snapshot = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: response,
            planType: "plus",
            capturedAt: capturedAt
        ))

        XCTAssertEqual(snapshot.windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(snapshot.displayWindow?.durationMinutes, 300)
        XCTAssertEqual(
            OpenAIUsageFormatter.menuBarText(snapshot: snapshot, now: capturedAt),
            "O 14% · 3h"
        )
    }

    func testDecoder_clampsPercentagesAndToleratesNullWindowFields() throws {
        let response: [String: Any] = [
            "rateLimits": limit(
                primary: ["usedPercent": -12, "windowDurationMins": NSNull(), "resetsAt": NSNull()],
                secondary: ["usedPercent": 135, "windowDurationMins": 10_080, "resetsAt": NSNull()]
            )
        ]

        let snapshot = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: response,
            planType: nil,
            capturedAt: capturedAt
        ))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
        XCTAssertNil(snapshot.windows[0].durationMinutes)
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 100)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 0)
    }

    func testCredits_supportZeroUnlimitedAndMissing() throws {
        let zero = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: ["rateLimits": limit(
                primary: window(used: 0, duration: 10_080, reset: nil),
                credits: ["hasCredits": false, "unlimited": false, "balance": "0"]
            )],
            planType: nil,
            capturedAt: capturedAt
        ))
        XCTAssertEqual(zero.credits?.displayBalance, "0")

        let unlimited = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: ["rateLimits": limit(
                primary: window(used: 0, duration: 10_080, reset: nil),
                credits: ["hasCredits": true, "unlimited": true, "balance": NSNull()]
            )],
            planType: nil,
            capturedAt: capturedAt
        ))
        XCTAssertEqual(unlimited.credits?.displayBalance, "Unlimited")

        let missing = try XCTUnwrap(OpenAIUsageDecoder.decodeSnapshot(
            rateLimits: ["rateLimits": limit(primary: window(used: 0, duration: 10_080, reset: nil))],
            planType: nil,
            capturedAt: capturedAt
        ))
        XCTAssertNil(missing.credits)
    }

    func testAccountDecoder_distinguishesSupportedAuthenticationStates() {
        XCTAssertEqual(
            OpenAIUsageDecoder.decodeAccount(["account": ["type": "chatgpt", "planType": "pro"]]),
            .chatGPT(planType: "pro")
        )
        XCTAssertEqual(OpenAIUsageDecoder.decodeAccount(["account": ["type": "apiKey"]]), .apiKey)
        XCTAssertEqual(OpenAIUsageDecoder.decodeAccount(["account": NSNull()]), .signedOut)
        XCTAssertEqual(OpenAIUsageDecoder.decodeAccount(["account": ["type": "amazonBedrock"]]), .unsupported)
    }

    func testJSONLDecoder_handlesSplitCoalescedAndMalformedLines() {
        var decoder = CodexJSONLStreamDecoder()
        XCTAssertTrue(decoder.append(Data("{\"id\":1".utf8)).isEmpty)

        let messages = decoder.append(Data("}\nnot-json\n{\"method\":\"account/rateLimits/updated\"}\r\n".utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(messages[1]["method"] as? String, "account/rateLimits/updated")
    }

    func testExecutableResolverFindsConductorStableApplicationSupportSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root
            .appendingPathComponent("com.conductor.app", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("codex")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            LoginShellExecutableResolver.resolve(
                "codex",
                searchPaths: [],
                applicationSupportDirectories: [root]
            ),
            executable
        )
    }

    func testAbsoluteResetFormattingIncludesLocalDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reset = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 13,
            minute: 51
        ))!

        XCTAssertEqual(
            OpenAIUsageFormatter.absoluteResetTime(
                reset,
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "Jul 22, 2026 at 1:51 PM"
        )
    }

    private func window(used: Int, duration: Int, reset: Date?) -> [String: Any] {
        [
            "usedPercent": used,
            "windowDurationMins": duration,
            "resetsAt": reset.map { Int($0.timeIntervalSince1970) } ?? NSNull()
        ]
    }

    private func limit(
        primary: [String: Any],
        secondary: [String: Any]? = nil,
        credits: [String: Any]? = nil,
        plan: String? = nil,
        name: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "primary": primary,
            "secondary": secondary ?? NSNull()
        ]
        if let credits { result["credits"] = credits }
        if let plan { result["planType"] = plan }
        if let name { result["limitName"] = name }
        return result
    }
}

@MainActor
final class OpenAIUsageServiceTests: XCTestCase {
    func testOptOutNeverStartsClientOrRefreshes() async {
        let client = FakeCodexUsageClient()
        let service = OpenAIUsageService(integrationsEnabled: { false }, clientFactory: { client })
        service.start()
        service.refreshNow()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.rateLimitReadCount, 0)
        service.stop()
    }

    func testSparseNotificationTriggersFullRefetch() async throws {
        let client = FakeCodexUsageClient()
        let service = OpenAIUsageService(integrationsEnabled: { true }, clientFactory: { client })
        service.start()

        let didConnect = await waitUntil { client.rateLimitReadCount == 1 }
        XCTAssertTrue(didConnect)
        guard case .connected = service.state else {
            return XCTFail("Expected connected state")
        }

        client.onRateLimitsChanged?()
        let didRefetch = await waitUntil { client.rateLimitReadCount == 2 }
        XCTAssertTrue(didRefetch)
        service.stop()
    }

    func testMissingExecutableSurfacesUnavailableState() async {
        let client = FakeCodexUsageClient()
        client.connectError = CodexAppServerError.executableNotFound
        let service = OpenAIUsageService(integrationsEnabled: { true }, clientFactory: { client })
        service.start()

        let becameUnavailable = await waitUntil {
            if case .unavailable = service.state { return true }
            return false
        }
        XCTAssertTrue(becameUnavailable)
        service.stop()
    }

    func testLastGoodSnapshotSurvivesFiveMinuteGraceWindow() async {
        let client = FakeCodexUsageClient()
        let time = MutableTestTime(Date(timeIntervalSince1970: 1_752_600_000))
        let service = OpenAIUsageService(
            integrationsEnabled: { true },
            clientFactory: { client },
            clock: OpenAIUsageClock(
                now: { time.now },
                sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) }
            )
        )
        service.start()
        let didConnect = await waitUntil { client.rateLimitReadCount == 1 }
        XCTAssertTrue(didConnect)

        client.rateLimitsError = CodexAppServerError.serverError
        time.now = time.now.addingTimeInterval(4 * 60)
        client.onRateLimitsChanged?()
        let didUseGraceSnapshot = await waitUntil { client.rateLimitReadCount == 3 }
        XCTAssertTrue(didUseGraceSnapshot)
        guard case .connected = service.state else {
            return XCTFail("Expected last good snapshot during grace window")
        }

        time.now = time.now.addingTimeInterval(2 * 60)
        client.onRateLimitsChanged?()
        let didExpireGraceSnapshot = await waitUntil { client.rateLimitReadCount == 5 }
        XCTAssertTrue(didExpireGraceSnapshot)
        guard case .error = service.state else {
            return XCTFail("Expected error after grace window")
        }
        service.stop()
    }

    func testUnexpectedExitReconnectsWithBackoff() async {
        let first = FakeCodexUsageClient()
        let second = FakeCodexUsageClient()
        var clients = [first, second]
        let service = OpenAIUsageService(
            integrationsEnabled: { true },
            clientFactory: { clients.removeFirst() },
            clock: OpenAIUsageClock(
                now: Date.init,
                sleep: { seconds in
                    if seconds >= 60 {
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                }
            )
        )
        service.start()
        let firstConnected = await waitUntil { first.connectCount == 1 && first.rateLimitReadCount == 1 }
        XCTAssertTrue(firstConnected)

        first.onUnexpectedExit?()
        let secondConnected = await waitUntil { second.connectCount == 1 && second.rateLimitReadCount == 1 }
        XCTAssertTrue(secondConnected)
        service.stop()
    }

    func testServerErrorRefreshesExpiredTokenAndRetriesFullSnapshot() async {
        let client = FakeCodexUsageClient()
        let service = OpenAIUsageService(integrationsEnabled: { true }, clientFactory: { client })
        service.start()

        let didConnect = await waitUntil { client.rateLimitReadCount == 1 }
        XCTAssertTrue(didConnect)
        XCTAssertEqual(client.accountRefreshRequests, [true])

        client.queuedRateLimitsErrors = [CodexAppServerError.serverError]
        client.onRateLimitsChanged?()

        let didRecover = await waitUntil { client.rateLimitReadCount == 3 }
        XCTAssertTrue(didRecover)
        XCTAssertEqual(client.accountRefreshRequests, [true, false, true])
        guard case .connected = service.state else {
            return XCTFail("Expected token refresh retry to restore connected state")
        }
        service.stop()
    }

    func testManualRefreshProactivelyRefreshesToken() async {
        let client = FakeCodexUsageClient()
        let service = OpenAIUsageService(integrationsEnabled: { true }, clientFactory: { client })
        service.start()

        let didConnect = await waitUntil { client.rateLimitReadCount == 1 }
        XCTAssertTrue(didConnect)
        service.refreshNow()

        let didRefresh = await waitUntil { client.rateLimitReadCount == 2 }
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(client.accountRefreshRequests, [true, true])
        service.stop()
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class FakeCodexUsageClient: CodexUsageClient {
    var onRateLimitsChanged: (() -> Void)?
    var onUnexpectedExit: (() -> Void)?

    var connectError: Error?
    var rateLimitsError: Error?
    var queuedRateLimitsErrors: [Error] = []
    private(set) var connectCount = 0
    private(set) var rateLimitReadCount = 0
    private(set) var accountRefreshRequests: [Bool] = []

    func connect() async throws {
        connectCount += 1
        if let connectError { throw connectError }
    }

    func readAccount(refreshToken: Bool) async throws -> [String: Any] {
        accountRefreshRequests.append(refreshToken)
        return ["account": ["type": "chatgpt", "planType": "pro"]]
    }

    func readRateLimits() async throws -> [String: Any] {
        rateLimitReadCount += 1
        if !queuedRateLimitsErrors.isEmpty {
            throw queuedRateLimitsErrors.removeFirst()
        }
        if let rateLimitsError { throw rateLimitsError }
        return [
            "rateLimits": [
                "primary": [
                    "usedPercent": 3,
                    "windowDurationMins": 10_080,
                    "resetsAt": Int(Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970)
                ],
                "secondary": NSNull(),
                "credits": ["hasCredits": false, "unlimited": false, "balance": "0"]
            ]
        ]
    }

    func disconnect() { }
}

private final class MutableTestTime {
    var now: Date
    init(_ now: Date) { self.now = now }
}
