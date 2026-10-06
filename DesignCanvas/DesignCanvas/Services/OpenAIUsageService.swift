// Observable read-only ChatGPT/Codex usage state. Data comes from the local
// Codex App Server, which shares the active Codex login and owns all credential
// handling. This service never switches accounts or mutates usage/credits.

import Foundation
import Observation

struct OpenAIRateLimitWindow: Equatable, Identifiable {
    let slot: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var id: String { "\(slot)-\(durationMinutes ?? -1)-\(resetsAt?.timeIntervalSince1970 ?? -1)" }
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var isWeekly: Bool { durationMinutes == 7 * 24 * 60 }
}

struct OpenAINamedLimit: Equatable, Identifiable {
    let id: String
    let name: String
    let windows: [OpenAIRateLimitWindow]

    var displayWindow: OpenAIRateLimitWindow? {
        windows.sorted(by: OpenAIUsageSnapshot.windowSort).first
    }
}

struct OpenAICreditsSnapshot: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    var displayBalance: String {
        if unlimited { return "Unlimited" }
        return balance ?? "—"
    }
}

struct OpenAIUsageSnapshot: Equatable {
    let planType: String?
    let windows: [OpenAIRateLimitWindow]
    let additionalLimits: [OpenAINamedLimit]
    let credits: OpenAICreditsSnapshot?
    let capturedAt: Date

    var displayWindow: OpenAIRateLimitWindow? {
        windows.sorted(by: Self.windowSort).first
    }

    var planDisplayName: String {
        OpenAIUsageFormatter.planDisplayName(planType)
    }

    static func windowSort(_ lhs: OpenAIRateLimitWindow, _ rhs: OpenAIRateLimitWindow) -> Bool {
        let lhsDuration = lhs.durationMinutes ?? Int.max
        let rhsDuration = rhs.durationMinutes ?? Int.max
        if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
        return lhs.slot < rhs.slot
    }
}

enum OpenAIAccountState: Equatable {
    case chatGPT(planType: String?)
    case signedOut
    case apiKey
    case unsupported
}

enum OpenAIUsageDecoder {
    static func decodeAccount(_ json: [String: Any]) -> OpenAIAccountState {
        guard let account = json["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return .signedOut
        }

        switch type {
        case "chatgpt":
            return .chatGPT(planType: account["planType"] as? String)
        case "apiKey":
            return .apiKey
        default:
            return .unsupported
        }
    }

    static func decodeSnapshot(
        rateLimits json: [String: Any],
        planType: String?,
        capturedAt: Date
    ) -> OpenAIUsageSnapshot? {
        let legacy = json["rateLimits"] as? [String: Any]
        let byLimitID = json["rateLimitsByLimitId"] as? [String: Any]
        let canonical = (byLimitID?["codex"] as? [String: Any]) ?? legacy
        guard let canonical else { return nil }

        let windows = decodeWindows(canonical)
        guard !windows.isEmpty else { return nil }

        let additionalLimits: [OpenAINamedLimit] = (byLimitID ?? [:]).compactMap { key, value in
            guard key != "codex", let limit = value as? [String: Any] else { return nil }
            let limitWindows = decodeWindows(limit)
            guard !limitWindows.isEmpty else { return nil }
            let suppliedName = (limit["limitName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = suppliedName.flatMap { $0.isEmpty ? nil : $0 } ?? key
            return OpenAINamedLimit(
                id: key,
                name: displayName,
                windows: limitWindows
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return OpenAIUsageSnapshot(
            planType: planType ?? canonical["planType"] as? String,
            windows: windows,
            additionalLimits: additionalLimits,
            credits: decodeCredits(canonical) ?? legacy.flatMap(decodeCredits),
            capturedAt: capturedAt
        )
    }

    private static func decodeWindows(_ limit: [String: Any]) -> [OpenAIRateLimitWindow] {
        [("primary", limit["primary"]), ("secondary", limit["secondary"])].compactMap { slot, raw in
            guard let block = raw as? [String: Any],
                  let used = number(block["usedPercent"]) else { return nil }
            let duration = number(block["windowDurationMins"])
            let resetSeconds = double(block["resetsAt"])
            return OpenAIRateLimitWindow(
                slot: slot,
                usedPercent: min(100, max(0, used)),
                durationMinutes: duration,
                resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    private static func decodeCredits(_ limit: [String: Any]) -> OpenAICreditsSnapshot? {
        guard let credits = limit["credits"] as? [String: Any] else { return nil }
        return OpenAICreditsSnapshot(
            hasCredits: boolean(credits["hasCredits"]) ?? false,
            unlimited: boolean(credits["unlimited"]) ?? false,
            balance: credits["balance"] as? String
        )
    }

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}

enum CompactUsageCountdownFormatter {
    static func string(until reset: Date, now: Date) -> String {
        let totalMinutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 { return "\(totalHours)h" }
        return "\(totalHours / 24)d"
    }
}

enum OpenAIUsageFormatter {
    static func menuBarText(snapshot: OpenAIUsageSnapshot, now: Date) -> String {
        guard let window = snapshot.displayWindow else { return "O —" }
        var text = "O \(window.usedPercent)%"
        if let reset = window.resetsAt {
            text += " · \(CompactUsageCountdownFormatter.string(until: reset, now: now))"
        }
        return text
    }

    static func windowTitle(_ window: OpenAIRateLimitWindow) -> String {
        guard let minutes = window.durationMinutes else { return "Usage" }
        switch minutes {
        case 5 * 60:
            return "5-hour usage"
        case 7 * 24 * 60:
            return "Weekly usage"
        default:
            if minutes.isMultiple(of: 24 * 60) {
                return "\(minutes / (24 * 60))-day usage"
            }
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60)-hour usage"
            }
            return "\(minutes)-minute usage"
        }
    }

    static func planDisplayName(_ planType: String?) -> String {
        let suffix: String
        switch planType {
        case "free": suffix = "Free"
        case "go": suffix = "Go"
        case "plus": suffix = "Plus"
        case "pro": suffix = "Pro"
        case "prolite": suffix = "Pro Lite"
        case "team": suffix = "Team"
        case "self_serve_business_usage_based", "business": suffix = "Business"
        case "enterprise_cbp_usage_based", "enterprise": suffix = "Enterprise"
        case "edu": suffix = "Edu"
        default: return "ChatGPT"
        }
        return "ChatGPT \(suffix)"
    }

    static func absoluteResetTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
}

struct OpenAIUsageClock {
    let now: () -> Date
    let sleep: (TimeInterval) async -> Void

    static let live = OpenAIUsageClock(
        now: Date.init,
        sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    )
}

@Observable
@MainActor
final class OpenAIUsageService {
    enum State: Equatable {
        case loading
        case connected(OpenAIUsageSnapshot)
        case signedOut
        case apiKeyUnsupported
        case unavailable(String)
        case error(String)
    }

    private(set) var state: State = .loading

    private static let pollInterval: TimeInterval = 60
    private static let snapshotGraceWindow: TimeInterval = 5 * 60

    private let integrationsEnabled: () -> Bool
    private let clientFactory: @MainActor () -> CodexUsageClient
    private let clock: OpenAIUsageClock

    private var client: CodexUsageClient?
    private var connectionID: UUID?
    private var connectTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var didStart = false
    private var reconnectDelay: TimeInterval = 1
    private var isRefreshing = false
    private var refreshQueued = false
    private var queuedRefreshRequiresTokenRefresh = false
    private var lastGoodSnapshot: OpenAIUsageSnapshot?

    init(
        integrationsEnabled: @escaping () -> Bool = { BuildPolicy.accountIntegrationsEnabled },
        clientFactory: @escaping @MainActor () -> CodexUsageClient = { CodexAppServerClient() },
        clock: OpenAIUsageClock = .live
    ) {
        self.integrationsEnabled = integrationsEnabled
        self.clientFactory = clientFactory
        self.clock = clock
    }

    func start() {
        guard integrationsEnabled() else { return }
        guard !didStart else { return }
        didStart = true
        connect()
    }

    func stop() {
        didStart = false
        connectTask?.cancel()
        pollTask?.cancel()
        reconnectTask?.cancel()
        connectTask = nil
        pollTask = nil
        reconnectTask = nil
        connectionID = nil

        client?.onRateLimitsChanged = nil
        client?.onUnexpectedExit = nil
        client?.disconnect()
        client = nil
        isRefreshing = false
        refreshQueued = false
        queuedRefreshRequiresTokenRefresh = false
    }

    func refreshNow() {
        guard integrationsEnabled() else { return }
        if let client, let connectionID {
            requestRefresh(
                using: client,
                connectionID: connectionID,
                refreshToken: true
            )
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDelay = 1
        if lastGoodSnapshot == nil { state = .loading }
        connect()
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard didStart, connectTask == nil, client == nil else { return }

        let connectionID = UUID()
        let newClient = clientFactory()
        self.connectionID = connectionID
        client = newClient

        newClient.onRateLimitsChanged = { [weak self] in
            self?.handleRateLimitsChanged(connectionID: connectionID)
        }
        newClient.onUnexpectedExit = { [weak self] in
            self?.handleUnexpectedExit(connectionID: connectionID)
        }

        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await newClient.connect()
                guard self.didStart, self.connectionID == connectionID else {
                    newClient.disconnect()
                    return
                }
                self.connectTask = nil
                self.reconnectDelay = 1
                // A long-lived app-server keeps its in-memory ChatGPT token. Refresh
                // once per connection so launching/reconnecting cannot inherit an
                // expired credential and become permanently stuck in an error state.
                await self.refresh(
                    using: newClient,
                    connectionID: connectionID,
                    refreshToken: true
                )
                self.startPolling(using: newClient, connectionID: connectionID)
            } catch {
                guard self.connectionID == connectionID else { return }
                self.connectTask = nil
                newClient.disconnect()
                self.client = nil
                self.connectionID = nil
                self.applyFailure(error)
                self.scheduleReconnect()
            }
        }
    }

    private func handleUnexpectedExit(connectionID: UUID) {
        guard didStart, self.connectionID == connectionID else { return }
        connectTask?.cancel()
        connectTask = nil
        pollTask?.cancel()
        pollTask = nil
        client = nil
        self.connectionID = nil
        applyFailure(CodexAppServerError.disconnected)
        scheduleReconnect()
    }

    private func handleRateLimitsChanged(connectionID: UUID) {
        guard didStart,
              self.connectionID == connectionID,
              let client else { return }
        requestRefresh(using: client, connectionID: connectionID, refreshToken: false)
    }

    private func scheduleReconnect() {
        guard didStart, reconnectTask == nil else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clock.sleep(delay)
            guard !Task.isCancelled, self.didStart else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func startPolling(using client: CodexUsageClient, connectionID: UUID) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.didStart,
                  self.connectionID == connectionID {
                await self.clock.sleep(Self.pollInterval)
                guard !Task.isCancelled else { return }
                await self.refresh(
                    using: client,
                    connectionID: connectionID,
                    refreshToken: false
                )
            }
        }
    }

    // MARK: - Refresh

    private func requestRefresh(
        using client: CodexUsageClient,
        connectionID: UUID,
        refreshToken: Bool
    ) {
        guard didStart, self.connectionID == connectionID else { return }
        Task { @MainActor [weak self] in
            await self?.refresh(
                using: client,
                connectionID: connectionID,
                refreshToken: refreshToken
            )
        }
    }

    private func refresh(
        using client: CodexUsageClient,
        connectionID: UUID,
        refreshToken: Bool
    ) async {
        guard didStart, self.connectionID == connectionID else { return }
        if isRefreshing {
            refreshQueued = true
            queuedRefreshRequiresTokenRefresh = queuedRefreshRequiresTokenRefresh || refreshToken
            return
        }
        isRefreshing = true

        do {
            let refreshedState: State
            do {
                refreshedState = try await fetchState(
                    using: client,
                    refreshToken: refreshToken
                )
            } catch {
                // App Server does not necessarily refresh an in-memory ChatGPT token
                // before a rate-limit request. A server error can therefore persist
                // forever in an app that stays open. Refresh auth once and retry the
                // complete snapshot; other failures keep their existing handling.
                guard !refreshToken,
                      error as? CodexAppServerError == .serverError else {
                    throw error
                }
                refreshedState = try await fetchState(using: client, refreshToken: true)
            }

            guard didStart, self.connectionID == connectionID else {
                isRefreshing = false
                return
            }

            switch refreshedState {
            case .signedOut:
                lastGoodSnapshot = nil
                state = .signedOut

            case .apiKeyUnsupported:
                lastGoodSnapshot = nil
                state = .apiKeyUnsupported

            case .connected(let snapshot):
                lastGoodSnapshot = snapshot
                state = .connected(snapshot)

            case .loading, .unavailable(_), .error(_):
                state = refreshedState
            }
        } catch {
            guard self.connectionID == connectionID else {
                isRefreshing = false
                return
            }
            applyFailure(error)
        }

        isRefreshing = false
        if refreshQueued {
            let refreshToken = queuedRefreshRequiresTokenRefresh
            refreshQueued = false
            queuedRefreshRequiresTokenRefresh = false
            await refresh(
                using: client,
                connectionID: connectionID,
                refreshToken: refreshToken
            )
        }
    }

    private func fetchState(
        using client: CodexUsageClient,
        refreshToken: Bool
    ) async throws -> State {
        let accountJSON = try await client.readAccount(refreshToken: refreshToken)
        switch OpenAIUsageDecoder.decodeAccount(accountJSON) {
        case .signedOut:
            return .signedOut

        case .apiKey, .unsupported:
            return .apiKeyUnsupported

        case .chatGPT(let planType):
            let limitsJSON = try await client.readRateLimits()
            guard let snapshot = OpenAIUsageDecoder.decodeSnapshot(
                rateLimits: limitsJSON,
                planType: planType,
                capturedAt: clock.now()
            ) else {
                throw CodexAppServerError.protocolError
            }
            return .connected(snapshot)
        }
    }

    private func applyFailure(_ error: Error) {
        if let lastGoodSnapshot,
           clock.now().timeIntervalSince(lastGoodSnapshot.capturedAt) < Self.snapshotGraceWindow {
            state = .connected(lastGoodSnapshot)
            return
        }

        if error as? CodexAppServerError == .executableNotFound {
            state = .unavailable("Codex isn't installed")
        } else {
            state = .error((error as? LocalizedError)?.errorDescription ?? "Codex usage is unavailable")
        }
    }
}
