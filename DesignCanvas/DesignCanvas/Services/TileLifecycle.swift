// Manages the WKWebView pool and LOD state machine (Screenshot/Queued/LoadingLive/Live).
// Pool of 6-70 live views (scales with RAM). Viewport-based promotion, hover-to-promote,
// lazy LRU eviction (only when pool is full), crossfade transitions, and process crash
// recovery. "Ambient State" loading UX.

import AppKit
import WebKit

class TileLifecycle {

    /// Maximum concurrent live WKWebViews. Each uses ~30-80MB RAM.
    /// Scales with system memory for the best experience on each machine.
    static var maxLiveViews: Int = {
        let memoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if memoryGB <= 8 { return 6 }
        if memoryGB <= 16 { return 8 }
        if memoryGB <= 31 { return 12 }
        if memoryGB <= 64 { return 50 }
        return 70
    }()

    // MARK: - Frame state

    enum FrameState { case screenshot, queued, loadingLive, live }

    private(set) var frameStates: [UUID: FrameState] = [:]
    private var lastInteraction: [UUID: Date] = [:]
    private var generationTokens: [UUID: Int] = [:]

    // MARK: - Pool

    private struct PoolEntry {
        let webView: WKWebView
        var assignedFrame: UUID?
        var navDelegate: WebViewCoordinator?
    }

    private var pool: [PoolEntry] = []

    // MARK: - Dependencies

    weak var camera: CanvasCamera?
    weak var document: DocumentModel?
    weak var interactionRouter: InteractionRouter?
    weak var screenshotService: ScreenshotService?
    var isInDemoMode = false

    // MARK: - Timers & observation

    private var debounceWork: DispatchWorkItem?
    private var dwellTimers: [UUID: DispatchWorkItem] = [:]
    private var lastPromotionTime: Date = .distantPast
    private var lastRecalcTime: Date = .distantPast
    private var isRecalculating = false
    private var boundsObserver: NSObjectProtocol?
    private var magnifyObserver: NSObjectProtocol?

    // MARK: - Config

    private static let debounceDelay: TimeInterval = 0.3
    private static let dwellDelay: TimeInterval = 0.15
    private static let cooldown: TimeInterval = 0.25

    // MARK: - Init

    init(camera: CanvasCamera, document: DocumentModel, router: InteractionRouter) {
        self.camera = camera
        self.document = document
        self.interactionRouter = router
        buildPool()
    }

    private func buildPool() {
        for _ in 0..<Self.maxLiveViews {
            let config = WebKitConfig.shared.makeConfiguration()
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.isInspectable = true
            wv.allowsMagnification = false
            wv.setValue(false, forKey: "drawsBackground")
            pool.append(PoolEntry(webView: wv))
        }
    }

    func attach(to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in self?.scheduleRecalc() }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.recalculate() }
    }

    // MARK: - Removed route handling

    /// React to a route being marked as removed in DocumentModel.
    /// Demotes any live WKWebView (capturing final screenshot), exits focus mode,
    /// and leaves the frame in .screenshot state so the ghost overlay can display.
    func handleRouteRemoved(frameId: UUID) {
        let state = frameStates[frameId]
        if state == .live || state == .loadingLive {
            demote(frameId: frameId)
        }
        if interactionRouter?.activeFrameId == frameId {
            interactionRouter?.deactivateAll()
        }
        frameStates[frameId] = .screenshot
    }

    /// React to a previously-removed route being restored (file reappeared on disk).
    /// Frame is already in .screenshot state — just trigger recalc so normal promotion
    /// logic can pick it up based on viewport proximity.
    func handleRouteRestored(frameId: UUID) {
        scheduleRecalc()
    }

    // MARK: - Debounced recalculation

    /// Coalesced recalculation — safe to call from updateNSView on every render.
    func scheduleRecalc() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recalculate() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }

    func recalculate() {
        guard !isInDemoMode else { return }
        guard let camera, let document else { return }
        // Prevent re-entrant calls (promote/demote can trigger SwiftUI updates → updateNSView → recalculate)
        guard !isRecalculating else { return }
        // Throttle: don't recalculate more than once per debounce interval
        let now = Date()
        if now.timeIntervalSince(lastRecalcTime) < Self.debounceDelay {
            scheduleRecalc()
            return
        }
        lastRecalcTime = now
        isRecalculating = true
        defer { isRecalculating = false }

        if hypot(camera.velocity.dx, camera.velocity.dy) > 500 { return }

        let visible = camera.visibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)

        let visibleCandidates = document.routes
            .filter { !$0.isRemoved }
            .filter { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.effectiveHeight).intersects(visible) }
            .sorted { dist($0, center) < dist($1, center) }

        let visibleSet = Set(visibleCandidates.map(\.id))
        let currentlyLive = Set(frameStates.filter { $0.value == .live || $0.value == .loadingLive }.map(\.key))

        // Lazy eviction: never demote based on viewport. Promote in-viewport screenshots
        // up to the pool cap; promote() handles eviction via findEvictionCandidate when
        // the pool is full, preferring offscreen-stale frames as victims.
        for route in visibleCandidates.prefix(Self.maxLiveViews) where !currentlyLive.contains(route.id) {
            promote(frameId: route.id)
        }

        // Mark in-viewport overflow (frames that couldn't promote) as queued
        let liveAfter = Set(frameStates.filter { $0.value == .live || $0.value == .loadingLive }.map(\.key))
        for route in visibleCandidates where !liveAfter.contains(route.id) {
            if frameStates[route.id] == .screenshot || frameStates[route.id] == nil {
                frameStates[route.id] = .queued
                interactionRouter?.findContainer(withId: route.id)?.applyVisualState()
            }
        }
        // Clear queued state for frames no longer in viewport
        for (id, state) in frameStates where state == .queued && !visibleSet.contains(id) {
            frameStates[id] = .screenshot
            interactionRouter?.findContainer(withId: id)?.applyVisualState()
        }
    }

    private func dist(_ route: RouteFrame, _ center: CGPoint) -> CGFloat {
        hypot(route.x + route.width / 2 - center.x, route.y + route.effectiveHeight / 2 - center.y)
    }

    // MARK: - Promote (Screenshot → Live)

    func promote(frameId: UUID) {
        guard !isInDemoMode else { return }
        guard let container = interactionRouter?.findContainer(withId: frameId),
              let document else { return }
        if let s = frameStates[frameId], s != .screenshot && s != .queued { return }

        guard let idx = availablePoolIndex() else {
            if let victim = findEvictionCandidate(excluding: frameId) {
                demote(frameId: victim)
                promote(frameId: frameId)
            }
            return
        }

        let gen = nextGen(frameId)
        frameStates[frameId] = .loadingLive
        syncScreenshotServiceState()
        container.applyVisualState()
        pool[idx].assignedFrame = frameId

        let wv = pool[idx].webView
        wv.alphaValue = 0
        container.attachWebView(wv)

        // Register metrics handler AFTER attach (so removeMetricsHandler in attach targets old webview).
        // Height is cached on the container for on-demand "Fit to Content" — never auto-updates the route.
        // Also calls container.onHeightMeasured so "Fit to Content" fallback path works.
        let handler = FrameMetricsHandler()
        handler.onHeightMeasured = { [weak container] h in
            container?.lastMeasuredContentHeight = h
            container?.onHeightMeasured?(h)
        }
        // Safety: remove any stale handler before adding (belt-and-suspenders against race conditions)
        wv.configuration.userContentController.removeScriptMessageHandler(
            forName: FrameMetricsHandler.messageName
        )
        wv.configuration.userContentController.add(handler, name: FrameMetricsHandler.messageName)
        container.storeMetricsHandler(handler)

        // Navigation delegate — stored in pool entry to prevent deallocation
        let nav = WebViewCoordinator()
        nav.onLoadingStarted = { [weak self] in
            // Storm detection: count navigations that start while the frame is
            // already steady-live. The initial promote-load happens with state
            // .loadingLive (set above) and TileLifecycle.reloadRoute also flips
            // to .loadingLive before reloading, so neither is counted.
            // HMR's `location.reload()` fires here while state is still .live —
            // exactly what we want to count toward the storm threshold.
            // WebKit calls navigation delegates on the main thread, so it's safe
            // to assume MainActor isolation when crossing into AppServices.
            guard let self, self.frameStates[frameId] == .live else { return }
            MainActor.assumeIsolated {
                AppServices.shared.stormDetector.recordReload(frameId: frameId)
            }
        }
        nav.onLoadingFinished = { [weak self, weak container] in
            guard let self, self.generationTokens[frameId] == gen else { return }
            container?.hideLoading()
            container?.hideError()
            container?.triggerHeightMeasurement(wv)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wv.animator().alphaValue = 1.0
            }
            self.frameStates[frameId] = .live
            self.lastInteraction[frameId] = Date()
            self.syncScreenshotServiceState()
            container?.applyVisualState()

            // Snapshot the live view for cache — avoids double-render by ScreenshotService
            wv.takeSnapshot(with: nil) { [weak self] image, _ in
                if let image { self?.saveFreshScreenshot(image, frameId: frameId) }
            }
        }
        nav.onLoadingFailed = { [weak container] msg in
            container?.showError("Load failed: \(msg)")
        }
        nav.onProcessTerminated = { [weak self] in self?.handleProcessCrash() }
        nav.onPossibleRouteRemoval = {
            // 404 from dev server — trigger file system re-validation instead of direct removal.
            // RouteDiscovery will re-scan and mergeDiscoveredRoutes() marks orphans as removed.
            Task { @MainActor in
                AppServices.shared.triggerRouteDiscovery()
            }
        }
        wv.navigationDelegate = nav
        pool[idx].navDelegate = nav

        // Load URL — route-aware resolution so this route's binding (not the document's
        // primary) drives the origin in a multi-server canvas.
        if let route = document.routes.first(where: { $0.id == frameId }),
           let loadURL = document.url(for: route) {
            container.originalURL = loadURL
            wv.load(URLRequest(url: loadURL))
            FileLogger.shared.log("Loaded route \(route.path) → \(loadURL.absoluteString) into pool slot", tag: "TileLifecycle")
        }
    }

    // MARK: - Demote (Live → Screenshot)

    private var demotingFrames: Set<UUID> = []

    func demote(frameId: UUID) {
        // Never demote the frame the user is actively dragging
        guard !(interactionRouter?.draggingFrameIds.contains(frameId) ?? false) else { return }
        // Guard against re-entrant demotes (async snapshot still in-flight)
        guard !demotingFrames.contains(frameId) else { return }

        guard let container = interactionRouter?.findContainer(withId: frameId),
              let wv = container.webView else {
            frameStates[frameId] = .screenshot
            return
        }

        // Immediately mark as screenshot and release pool slot so promote() can reuse it.
        // The snapshot below is best-effort — we don't block on it.
        demotingFrames.insert(frameId)
        frameStates[frameId] = .screenshot
        interactionRouter?.onFrameWillDetach(frameId: frameId)

        // Remove metrics handler BEFORE snapshot — prevents duplicate registration
        wv.configuration.userContentController.removeScriptMessageHandler(
            forName: FrameMetricsHandler.messageName
        )
        // DON'T return to pool yet — keep the slot reserved until cleanup is complete.
        // Returning early let promote() grab a webview mid-snapshot, causing reload storms.
        let gen = nextGen(frameId)

        wv.takeSnapshot(with: nil) { [weak self, weak container, weak wv] image, _ in
            guard let self else { return }
            self.demotingFrames.remove(frameId)
            guard self.generationTokens[frameId] == gen else {
                // Stale — clean up message handlers before returning to pool
                // (dcNavChange may still be registered from the previous attachWebView)
                if let wv {
                    wv.configuration.userContentController.removeScriptMessageHandler(forName: "dcNavChange")
                    wv.configuration.userContentController.removeScriptMessageHandler(forName: FrameMetricsHandler.messageName)
                    self.returnToPool(wv)
                }
                return
            }
            if let image { self.saveFreshScreenshot(image, frameId: frameId) }
            if let container, let url = self.document?.screenshots[frameId] {
                container.showScreenshot(fileURL: url)
            }

            guard let wv else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wv.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak container] in
                let detached = container?.detachWebView()
                detached?.stopLoading()
                detached?.load(URLRequest(url: URL(string: "about:blank")!))
                detached?.navigationDelegate = nil
                // Now return to pool — webview is fully cleaned up
                if let detached { self?.returnToPool(detached) }
            })
        }
    }

    // MARK: - Eviction

    private func findEvictionCandidate(excluding: UUID?) -> UUID? {
        guard let camera, let router = interactionRouter else { return nil }
        let center = CGPoint(x: camera.visibleRect.midX, y: camera.visibleRect.midY)

        return frameStates
            .filter { $0.value == .live && $0.key != excluding
                && router.activeFrameId != $0.key
                && !router.draggingFrameIds.contains($0.key) }
            .compactMap { id, _ -> (UUID, CGFloat)? in
                let container = router.findContainer(withId: id)
                if let wv = container?.webView, wv.window?.firstResponder === wv { return nil }
                let route = document?.routes.first { $0.id == id }
                let d = route.map { dist($0, center) } ?? 0
                let stale = CGFloat(Date().timeIntervalSince(lastInteraction[id] ?? .distantPast) * 100)
                return (id, d + stale)
            }
            .max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - Hover-to-promote

    func onHoverEnter(frameId: UUID) {
        // Never promote removed routes — they stay as ghost screenshots
        guard document?.routes.first(where: { $0.id == frameId })?.isRemoved != true else { return }
        // Skip hover-to-promote while a frame is being dragged
        guard interactionRouter?.isDragging != true else { return }
        if frameStates[frameId] == .live { lastInteraction[frameId] = Date(); return }
        guard frameStates[frameId] == .screenshot || frameStates[frameId] == .queued || frameStates[frameId] == nil else { return }
        guard Date().timeIntervalSince(lastPromotionTime) >= Self.cooldown else { return }
        if let cam = camera, hypot(cam.velocity.dx, cam.velocity.dy) > 200 { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellTimers.removeValue(forKey: frameId)
            if self.availablePoolIndex() == nil {
                guard let victim = self.findEvictionCandidate(excluding: frameId) else { return }
                self.demote(frameId: victim)
            }
            self.promote(frameId: frameId)
            self.lastPromotionTime = Date()
        }
        dwellTimers[frameId]?.cancel()
        dwellTimers[frameId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDelay, execute: work)
    }

    func onHoverExit(frameId: UUID) {
        dwellTimers[frameId]?.cancel()
        dwellTimers.removeValue(forKey: frameId)
    }

    // MARK: - Route change reload

    /// Reload a frame's content when its route path changes.
    /// Live frames get an in-place URL reload; screenshot frames are promoted to live.
    func reloadRoute(frameId: UUID) {
        guard let document else { return }
        let state = frameStates[frameId]

        if state == .live || state == .loadingLive {
            guard let container = interactionRouter?.findContainer(withId: frameId),
                  let wv = container.webView else { return }
            if let route = document.routes.first(where: { $0.id == frameId }),
               let loadURL = document.url(for: route) {
                frameStates[frameId] = .loadingLive
                syncScreenshotServiceState()
                wv.load(URLRequest(url: loadURL))
                FileLogger.shared.log("Reloaded route \(route.path) → \(loadURL.absoluteString)", tag: "TileLifecycle")
            }
        } else if state == .screenshot || state == .queued || state == nil {
            if let container = interactionRouter?.findContainer(withId: frameId) {
                container.clearScreenshot()
            }
            document.screenshots.removeValue(forKey: frameId)
            promoteToLive(frameId: frameId)
        }
    }

    // MARK: - Context menu "Make Live"

    func promoteToLive(frameId: UUID) {
        if availablePoolIndex() == nil {
            guard let victim = findEvictionCandidate(excluding: frameId) else { return }
            demote(frameId: victim)
        }
        promote(frameId: frameId)
    }

    // MARK: - Crash recovery

    func handleProcessCrash() {
        print("TileLifecycle: WebContent process crashed — recovering")
        for (id, state) in frameStates where state == .live || state == .loadingLive {
            if let c = interactionRouter?.findContainer(withId: id) {
                c.hideLoading()
                interactionRouter?.onFrameWillDetach(frameId: id)
                _ = c.detachWebView()
                if let url = document?.screenshots[id] { c.showScreenshot(fileURL: url) }
            }
            frameStates[id] = .screenshot
        }
        pool.removeAll()
        buildPool()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.recalculate() }
    }

    // MARK: - Frame lifecycle

    func registerFrame(_ id: UUID) { frameStates[id] = frameStates[id] ?? .screenshot }

    func unregisterFrame(_ id: UUID) {
        if frameStates[id] == .live || frameStates[id] == .loadingLive { demote(frameId: id) }
        frameStates.removeValue(forKey: id)
        lastInteraction.removeValue(forKey: id)
        generationTokens.removeValue(forKey: id)
        dwellTimers[id]?.cancel()
        dwellTimers.removeValue(forKey: id)
    }

    // MARK: - Helpers

    /// True when any frame is actively loading a webview. Used to pause screenshot service.
    var hasLoadingFrames: Bool {
        frameStates.values.contains(.loadingLive)
    }

    /// Pause or resume the screenshot service based on whether any frames are loading.
    private func syncScreenshotServiceState() {
        let loading = hasLoadingFrames
        Task { @MainActor [weak screenshotService] in
            if loading {
                screenshotService?.pause()
            } else {
                screenshotService?.resume()
            }
        }
    }

    private func availablePoolIndex() -> Int? { pool.firstIndex { $0.assignedFrame == nil } }

    private func returnToPool(_ wv: WKWebView) {
        if let idx = pool.firstIndex(where: { $0.webView === wv }) {
            pool[idx].assignedFrame = nil
            pool[idx].navDelegate = nil
        }
    }

    private func nextGen(_ id: UUID) -> Int {
        let g = (generationTokens[id] ?? 0) + 1
        generationTokens[id] = g
        return g
    }

    func saveFreshScreenshot(_ image: NSImage, frameId: UUID) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(BuildPolicy.dataDirectoryName)/screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(frameId.uuidString).jpg")
        if let tiff = image.tiffRepresentation,
           let bmp = NSBitmapImageRep(data: tiff),
           let data = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: url)
            document?.screenshots[frameId] = url
        }
    }

    deinit {
        if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = magnifyObserver { NotificationCenter.default.removeObserver(o) }
        debounceWork?.cancel()
        dwellTimers.values.forEach { $0.cancel() }
    }
}
