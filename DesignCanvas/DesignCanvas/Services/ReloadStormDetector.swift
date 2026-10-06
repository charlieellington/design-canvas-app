// Detects "reload storms" — bursts of WKWebView reloads driven by HMR when an
// agent (or fast-typing human) saves many files in quick succession. Pauses
// live updates until the storm subsides; exposes observable state for SwiftUI
// chrome (PausedStatusCard) and the AppKit accent-halo on live frames.
//
// Flow: WebViewCoordinator.didStartProvisionalNavigation → TileLifecycle's
// onLoadingStarted callback → recordReload(frameId:) here. Per-frame coalesce
// folds CSS+JS+overlay HMR triplets into one event. Once > stormThreshold
// events accumulate inside stormWindow, enterPaused() fires the onEnterPaused
// closure (wired by AppServices) which calls stopLoading() on every live
// WKWebView. AppServices closures are the boundary between this pure-logic
// detector and AppKit; the detector itself imports no UI frameworks.

import Foundation
import Observation

@Observable
@MainActor
final class ReloadStormDetector {

    // MARK: - Tunables

    /// Reload events in the rolling window beyond which we declare a storm.
    static let stormThreshold = 5
    /// Rolling window for storm detection.
    static let stormWindow: TimeInterval = 20
    /// Per-frame events arriving within this window collapse into one event.
    static let coalesceWindow: TimeInterval = 0.75
    /// Auto-resume after this much quiet time while paused.
    static let quietWindow: TimeInterval = 20
    /// After resume / force-refresh, ignore events for this long so our own
    /// catch-up `wv.reload()` calls don't immediately re-trigger the storm.
    static let gracePeriod: TimeInterval = 2.0

    // MARK: - Observable state

    private(set) var isPaused: Bool = false
    private(set) var recentCount: Int = 0

    // MARK: - Wired by AppServices

    /// Stop loading on every live WKWebView and refresh visual state (accent halo).
    var onEnterPaused: (() -> Void)?
    /// Refresh visual state; if `reloadFrames`, also call `wv.reload()` on every live frame.
    var onResume: ((_ reloadFrames: Bool) -> Void)?
    /// Toolbar / card ↻: reload all live frames + recapture screenshots.
    /// Does NOT change pause state — caller decides via `resume(reloadFrames:)`.
    var onForceRefresh: (() -> Void)?

    // MARK: - Internal state

    private var rollingWindow: [Date] = []
    private var lastCommitAt: [UUID: Date] = [:]
    private var quietTimer: DispatchWorkItem?
    private var graceUntil: Date?

    // MARK: - Public API

    /// Record one reload event. Caller filters out the initial promote-load by
    /// only invoking on already-`.live` frames.
    ///
    /// Leading-edge per-frame debounce: the first event in a burst commits
    /// immediately; subsequent events on the same frame are suppressed for
    /// `coalesceWindow` so a CSS+JS+overlay HMR triplet folds into one event,
    /// while a sustained 200–2000ms reload cadence (real storm) still ticks.
    func recordReload(frameId: UUID) {
        if let g = graceUntil, Date() < g { return }
        let now = Date()
        if let last = lastCommitAt[frameId],
           now.timeIntervalSince(last) < Self.coalesceWindow {
            return
        }
        lastCommitAt[frameId] = now
        commitReload(at: now)
    }

    /// Note that a reload arrived but was suppressed by the pause policy.
    /// Resets the auto-resume quiet-timer so the agent is treated as still active.
    func noteSuppressedReload() {
        guard isPaused else { return }
        armQuietTimer()
    }

    private func commitReload(at: Date) {
        rollingWindow.append(at)
        prune(now: at)
        recentCount = rollingWindow.count

        if isPaused {
            armQuietTimer()
        } else if rollingWindow.count > Self.stormThreshold {
            enterPaused()
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.stormWindow)
        rollingWindow.removeAll { $0 < cutoff }
    }

    /// Enter paused mode. Stops in-flight loads; arms the quiet-timer.
    func enterPaused() {
        guard !isPaused else { return }
        isPaused = true
        FileLogger.shared.log(
            "Storm: entered paused after \(rollingWindow.count) reloads in \(Int(Self.stormWindow))s",
            tag: "Storm"
        )
        AnalyticsService.shared.capture(.stormDetected)
        onEnterPaused?()
        armQuietTimer()
    }

    /// Exit paused mode. If `reloadFrames`, callers will reload live frames.
    func resume(reloadFrames: Bool, source: String = "manual") {
        guard isPaused else { return }
        isPaused = false
        rollingWindow.removeAll()
        recentCount = 0
        quietTimer?.cancel()
        quietTimer = nil
        graceUntil = Date().addingTimeInterval(Self.gracePeriod)
        FileLogger.shared.log("Storm: resolved (\(source))", tag: "Storm")
        AnalyticsService.shared.capture(.stormResolved)
        onResume?(reloadFrames)
    }

    /// Force a refresh of all live frames + screenshots. Pause state untouched.
    /// Toolbar ↻ pairs this with `resume(reloadFrames:)`; card ↻ does not.
    func forceRefreshAll() {
        graceUntil = Date().addingTimeInterval(Self.gracePeriod)
        onForceRefresh?()
    }

    // MARK: - Auto-resume timer

    private func armQuietTimer() {
        quietTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPaused else { return }
            self.resume(reloadFrames: true, source: "auto, quiet \(Int(Self.quietWindow))s")
        }
        quietTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietWindow, execute: work)
    }
}
