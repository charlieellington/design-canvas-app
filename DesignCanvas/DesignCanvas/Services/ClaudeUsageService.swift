// Polls the unofficial `claude.ai/api/organizations/{org}/usage` endpoint and
// publishes a UsageState the pill view consumes. Auth is via the `sessionKey`
// cookie captured by ClaudeLoginSheet → this instance's `dataStore`.
//
// One instance per Claude account: account 1 polls `WKWebsiteDataStore.default()`,
// additional accounts poll their own persistent WebKit profile so two accounts'
// cookies (and usage) stay fully isolated. ClaudeAccountsManager owns the set.
//
// 60s cadence, paused while the app is hidden or backgrounded, refreshed on
// re-activation. 401 surfaces as `.unauthenticated`; transient errors keep
// the last good snapshot for ~5 minutes before falling back to `—`.

import Foundation
import AppKit
import Observation
import WebKit

@Observable
@MainActor
final class ClaudeUsageService: Identifiable {
    // `id` is synthesised as ObjectIdentifier(self) via Identifiable's default for
    // class types — lets each account drive a `.sheet(item:)` login presentation.
    static let shared = ClaudeUsageService()

    enum State {
        case unauthenticated
        case loading
        case connected(Snapshot)
        case freeTier
        case error(String)
    }

    struct Snapshot: Equatable {
        let fiveHourPct: Double          // 0...100, raw from API
        let fiveHourResetsAt: Date?      // nil when no 5-hour window is currently open
        let sevenDayPct: Double?
        let sevenDayResetsAt: Date?
        let sevenDayOpusPct: Double?
        let sevenDaySonnetPct: Double?
        let capturedAt: Date

        static let fiveHourSeconds: TimeInterval = 5 * 60 * 60

        // The pill needs to render something coherent both while a 5-hour window
        // is running (.session) and between sessions when only the weekly cap
        // carries signal (.weekly). The transition is driven entirely by the
        // presence of `fiveHourResetsAt`, which Anthropic now nulls out the
        // moment a session expires.
        enum DisplayMode: Equatable { case session, weekly }

        var displayMode: DisplayMode {
            if fiveHourResetsAt != nil { return .session }
            if sevenDayResetsAt != nil, (sevenDayPct ?? 0) > 0 { return .weekly }
            return .session
        }

        var displayPct: Double {
            switch displayMode {
            case .session: return fiveHourPct
            case .weekly:  return sevenDayPct ?? 0
            }
        }

        var displayResetsAt: Date? {
            switch displayMode {
            case .session: return fiveHourResetsAt
            case .weekly:  return sevenDayResetsAt
            }
        }

        /// Session-mode only. nil between sessions — no anchor to measure elapsed.
        func elapsedFraction(now: Date = Date()) -> Double? {
            guard let resets = fiveHourResetsAt else { return nil }
            let remaining = resets.timeIntervalSince(now)
            let elapsed = Self.fiveHourSeconds - remaining
            return max(0.0, min(1.0, elapsed / Self.fiveHourSeconds))
        }

        /// Session-mode only. nil when too early in the window (or between
        /// sessions) to project a meaningful end-of-period burn.
        func projectedEndOfPeriod(now: Date = Date()) -> Double? {
            guard let elapsed = elapsedFraction(now: now), elapsed >= 0.01 else { return nil }
            return fiveHourPct / elapsed
        }
    }

    // MARK: - Observed state

    private(set) var state: State = .unauthenticated
    private(set) var orgs: [Org] = []

    /// Persists across launches — user opted out (e.g. doesn't use Claude Code).
    var permanentlyHidden: Bool {
        get { UserDefaults.standard.bool(forKey: permanentlyHiddenKey) }
        set { UserDefaults.standard.set(newValue, forKey: permanentlyHiddenKey) }
    }

    /// In-memory only — dismissed for this launch (screen recordings, focus mode).
    var sessionHidden: Bool = false

    var isHidden: Bool {
        if !BuildPolicy.accountIntegrationsEnabled { return true }
        if permanentlyHidden || sessionHidden { return true }
        // Hide on .freeTier only for genuine single-org Free-tier accounts.
        // Multi-org users keep the pill visible so the workspace picker in the
        // popover stays reachable — otherwise picking an org without 5-hour
        // data permanently hides the pill with no recovery path.
        if case .freeTier = state, orgs.count <= 1 { return true }
        return false
    }

    // MARK: - Internals

    struct Org: Equatable, Hashable {
        let uuid: String
        let name: String
    }

    /// UserDefaults keys are namespaced per instance so two accounts don't clobber
    /// each other's workspace pick / hidden flag. Account 1 keeps the legacy
    /// un-prefixed keys (default `keyPrefix`) so existing settings survive.
    private var permanentlyHiddenKey: String { keyPrefix + "permanentlyHidden" }
    private var lastOrgUUIDKey: String { keyPrefix + "lastOrgUUID" }

    private static let baseURL = URL(string: "https://claude.ai")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let pollInterval: TimeInterval = 60
    private static let snapshotGraceWindow: TimeInterval = 5 * 60

    /// Isolated cookie jar this account authenticates against. Account 1 uses
    /// `.default()`; additional accounts use persistent WebKit profiles created
    /// via `WKWebsiteDataStore(forIdentifier:)`. Exposed so the login sheet can
    /// write the sign-in cookies into the right jar.
    let dataStore: WKWebsiteDataStore
    private let keyPrefix: String

    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var didStart = false
    private var lastGoodSnapshot: Snapshot?

    init(dataStore: WKWebsiteDataStore = .default(), keyPrefix: String = "claudeUsagePill.") {
        self.dataStore = dataStore
        self.keyPrefix = keyPrefix
    }

    // MARK: - Lifecycle

    func start() {
        guard BuildPolicy.accountIntegrationsEnabled else { return }
        guard !didStart else { return }
        didStart = true

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func stop() {
        didStart = false
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Fired on right-click → Refresh now and after a successful login.
    func refreshNow() {
        Task { await tick() }
    }

    func signOut() {
        Task {
            await ClaudeAuth.signOut(store: dataStore)
            self.state = .unauthenticated
            self.lastGoodSnapshot = nil
        }
    }

    func selectOrg(_ org: Org) {
        UserDefaults.standard.set(org.uuid, forKey: lastOrgUUIDKey)
        Task { await tick() }
    }

    /// Clears the persisted workspace pick so the next tick falls back to the
    /// first org returned by the API. Used by the View menu's "Show" path so
    /// a user who hid the pill while stuck on a no-data org gets a clean
    /// recovery on re-show.
    func resetSelectedOrg() {
        UserDefaults.standard.removeObject(forKey: lastOrgUUIDKey)
    }

    /// Clears this account's namespaced UserDefaults (workspace pick + hidden
    /// flag). Called when a secondary account is removed so a later re-add starts
    /// clean. Account 1 never calls this — its legacy keys are kept.
    func forgetPersistedSettings() {
        UserDefaults.standard.removeObject(forKey: lastOrgUUIDKey)
        UserDefaults.standard.removeObject(forKey: permanentlyHiddenKey)
    }

    /// Name of the org currently being polled — driven by `lastOrgUUID` if set,
    /// else the first org returned by the API. Nil before the first successful
    /// org fetch (signed out, loading, cold-start error).
    var currentOrgName: String? {
        guard !orgs.isEmpty else { return nil }
        if let saved = UserDefaults.standard.string(forKey: lastOrgUUIDKey),
           let match = orgs.first(where: { $0.uuid == saved }) {
            return match.name
        }
        return orgs.first?.name
    }

    /// UUID of the currently-selected org (matches `currentOrgName`). Used by the
    /// popover's multi-org radio group to highlight the active row.
    var currentOrgUUID: String? {
        guard !orgs.isEmpty else { return nil }
        if let saved = UserDefaults.standard.string(forKey: lastOrgUUIDKey),
           orgs.contains(where: { $0.uuid == saved }) {
            return saved
        }
        return orgs.first?.uuid
    }

    /// Short label distinguishing this account on the pill / menu-bar item
    /// (e.g. "Main" / "2nd"). Set by ClaudeAccountsManager per slot; nil shows no
    /// prefix (single-account users). Slot labels are unambiguous — unlike the old
    /// email-derived prefix, which collided when two accounts shared a prefix.
    var accountLabel: String? = nil

    // MARK: - Polling

    private func tick() async {
        guard BuildPolicy.accountIntegrationsEnabled else { return }
        // No isActive / window-visible guards: the menu bar pill needs the
        // poll to keep firing while the main canvas window is closed.
        guard let sessionKey = await ClaudeAuth.currentSessionKey(store: dataStore) else {
            state = .unauthenticated
            return
        }
        guard BuildPolicy.accountIntegrationsEnabled, !Task.isCancelled else { return }

        // Show .loading only on the very first fetch — avoid flicker on re-polls.
        if case .unauthenticated = state { state = .loading }

        do {
            let orgList = try await fetchOrganizations(sessionKey: sessionKey)
            self.orgs = orgList
            guard let org = pickOrg(from: orgList) else {
                state = .error("No organization on this account")
                return
            }
            let snapshot = try await fetchUsage(orgUUID: org.uuid, sessionKey: sessionKey)
            if let snapshot {
                lastGoodSnapshot = snapshot
                state = .connected(snapshot)
            } else {
                // Endpoint returned a payload with no five-hour utilization (Free tier).
                state = .freeTier
            }
        } catch UsageError.unauthorized {
            state = .unauthenticated
            lastGoodSnapshot = nil
        } catch {
            // Transient failure — keep showing the last good snapshot for the
            // grace window, then fall back to a muted error state.
            if let last = lastGoodSnapshot,
               Date().timeIntervalSince(last.capturedAt) < Self.snapshotGraceWindow {
                state = .connected(last)
            } else {
                state = .error("Couldn't reach claude.ai")
                lastGoodSnapshot = nil
            }
        }
    }

    private func pickOrg(from list: [Org]) -> Org? {
        if let saved = UserDefaults.standard.string(forKey: lastOrgUUIDKey),
           let match = list.first(where: { $0.uuid == saved }) {
            return match
        }
        return list.first
    }

    // MARK: - Networking

    private enum UsageError: Error { case unauthorized, badResponse }

    private func fetchOrganizations(sessionKey: String) async throws -> [Org] {
        let url = Self.baseURL.appendingPathComponent("/api/organizations")
        let data = try await get(url: url, sessionKey: sessionKey)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.badResponse
        }
        return array.compactMap { obj in
            guard let uuid = obj["uuid"] as? String else { return nil }
            let name = (obj["name"] as? String) ?? "Personal"
            return Org(uuid: uuid, name: name)
        }
    }

    /// Returns nil when the response indicates a Free-tier account (no
    /// five-hour utilization to display).
    private func fetchUsage(orgUUID: String, sessionKey: String) async throws -> Snapshot? {
        let url = Self.baseURL.appendingPathComponent("/api/organizations/\(orgUUID)/usage")
        let data = try await get(url: url, sessionKey: sessionKey)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        return UsageDecoder.decode(json: json, capturedAt: Date())
    }

    private func get(url: URL, sessionKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw UsageError.badResponse }
        return data
    }
}

// MARK: - Decoder

/// Defensive decoder for the unofficial usage payload. The shape isn't a stable
/// public contract, so we tolerate the two field-name conventions seen across
/// reverse-engineered references and silently ignore unknown keys.
enum UsageDecoder {
    static func decode(json: [String: Any], capturedAt: Date) -> ClaudeUsageService.Snapshot? {
        // `five_hour.resets_at` legitimately nulls between active 5-hour
        // windows on Max plans; only the presence of `utilization` decides
        // whether this is a usable response vs Free tier.
        guard let five = pickBlock(json, keys: ["five_hour", "fiveHour", "current_five_hour", "current_session"]),
              let pct = pickPct(five) else {
            return nil
        }
        let reset = pickDate(five)
        let week = pickBlock(json, keys: ["seven_day", "sevenDay", "weekly", "weekly_all_models"])
        let opus = pickBlock(json, keys: ["seven_day_opus", "sevenDayOpus", "weekly_opus"])
        let sonnet = pickBlock(json, keys: ["seven_day_sonnet", "sevenDaySonnet", "weekly_sonnet"])

        return ClaudeUsageService.Snapshot(
            fiveHourPct: pct,
            fiveHourResetsAt: reset,
            sevenDayPct: week.flatMap(pickPct),
            sevenDayResetsAt: week.flatMap(pickDate),
            sevenDayOpusPct: opus.flatMap(pickPct),
            sevenDaySonnetPct: sonnet.flatMap(pickPct),
            capturedAt: capturedAt
        )
    }

    private static func pickBlock(_ json: [String: Any], keys: [String]) -> [String: Any]? {
        for k in keys {
            if let block = json[k] as? [String: Any] { return block }
        }
        return nil
    }

    private static func pickPct(_ block: [String: Any]) -> Double? {
        for k in ["utilization", "percentage", "pct", "percent_used"] {
            if let raw = block[k] as? Double { return clampPct(raw) }
            if let raw = block[k] as? Int { return clampPct(Double(raw)) }
        }
        return nil
    }

    private static func pickDate(_ block: [String: Any]) -> Date? {
        for k in ["resets_at", "resetsAt", "reset_at", "resetAt", "next_reset"] {
            if let s = block[k] as? String, let d = parseISO8601(s) { return d }
        }
        return nil
    }

    private static func clampPct(_ raw: Double) -> Double {
        // Some responses use 0...1, others use 0...100.
        let normalized = raw <= 1.0 ? raw * 100 : raw
        return min(max(normalized, 0), 999)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
