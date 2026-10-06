// Captures screenshots of routes using an off-screen WKWebView. Three-tier capture strategy:
//   Pass 1: Fast capture on readyState complete — fills canvas quickly (~2s per route)
//   Pass 2: DOM MutationObserver — recaptures when DOM settles (500ms stable, 10s timeout)
//   Pass 3: Fallback — any routes that didn't settle get a final capture with 5s fixed delay
// Single entry point for all screenshot requests. Saves JPEG to disk, updates DocumentModel.

import AppKit
import WebKit

// MARK: - Stage 14.5a — canonical API surface

extension Notification.Name {
    /// Emitted AFTER the screenshot cache commits a fresh capture. Payload:
    ///   `["routeID": UUID, "cacheKey": String, "capturedAt": Date, "contentVersion": Int]`
    /// Consumers that hold an outdated cache key should ignore the post.
    static let screenshotDidUpdate = Notification.Name("DesignCanvas.ScreenshotDidUpdate")
}

/// Typed errors thrown by the canonical `capture` / `previewCapture` entry points.
enum CaptureError: Error {
    case staleNavigation     // navigation token changed mid-capture
    case cancelled           // Task.cancel() during sleep/snapshot
    case routeUnavailable    // route belongs to an inactive canvas — no live WebView
    case invalidImage        // takeSnapshot returned nil
    case noClientFrameId     // route hasn't been assigned its Stage 13 clientFrameId yet
}

/// Result of a single canonical capture. `cacheKey` is the SHA256 digest of
/// the composite key; `contentVersion` is the value at capture time so a
/// stale notification can be dropped cleanly.
struct CaptureResult {
    let image: NSImage
    let cacheKey: String
    let capturedAt: Date
    let contentVersion: Int
    let fileURL: URL?
}

@MainActor
class ScreenshotService: NSObject {

    let document: DocumentModel
    private var captureWebView: WKWebView?
    private var utilityWindow: NSWindow?
    private var activityToken: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var mainWindowObserver: NSObjectProtocol?
    private(set) var isCaptureInProgress = false

    /// Navigation token per route (Stage 14.5a). Each in-flight capture
    /// snapshots the token at start; on `webView(_:didStartProvisionalNavigation:)`
    /// we bump it so any pending snapshot can detect the page changed and
    /// discard before cache-committing. Token check happens at step 4 in the
    /// step-2 algorithm of the plan.
    private var navigationTokens: [UUID: Int] = [:]

    /// Per-frame mapping from `RouteFrame.id` (canvas identity) to the
    /// Stage 13 `clientFrameId` (share-time identity). Mac is the only direct
    /// caller of POST /create — until a share is created, this map is empty.
    /// Stage 16a/16b populate it via `assignClientFrameId(routeID:clientFrameId:)`.
    private var clientFrameIds: [UUID: UUID] = [:]

    /// Current `contentVersion` per route — driven by Stage 13 endpoints (finalise,
    /// PATCH /styling). 0 for routes that have not yet been shared.
    private var contentVersions: [UUID: Int] = [:]

    /// When true, the screenshot service yields to live webview loads.
    /// Set by TileLifecycle when frames are in .loadingLive state.
    private(set) var isPaused = false

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        print("[ScreenshotService] Paused — yielding to live webview loads")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        print("[ScreenshotService] Resumed")
    }

    /// Wait while paused, checking every 500ms. Returns false if task was cancelled.
    private func waitWhilePaused() async -> Bool {
        while isPaused {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    /// Directory for saved screenshots (app caches)
    private static var screenshotDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(BuildPolicy.dataDirectoryName)/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(document: DocumentModel) {
        self.document = document
        super.init()
        setupCaptureWebView()
        startMemoryPressureMonitor()
        attachUtilityWindowToMainWindow()
    }

    /// Pause capture when system is under memory pressure, resume when it clears.
    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let status = source.data
            if status.contains(.critical) || status.contains(.warning) {
                if !self.isPaused {
                    print("[ScreenshotService] Memory pressure detected — pausing capture")
                    self.pause()
                }
            }
        }
        source.setCancelHandler { }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
        if let observer = mainWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Tie the utility window to the main canvas window so it can never be left
    /// orphaned on screen. Without this, closing the canvas leaves the off-screen
    /// utility window visible — macOS makes it the new key window and re-positions
    /// it onto a screen, painting the last-captured route on the user's desktop.
    private func attachUtilityWindowToMainWindow() {
        if let window = NSApp.windows.first(where: isCanvasWindow) {
            attach(to: window)
            return
        }
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let window = notification.object as? NSWindow,
                  self.isCanvasWindow(window) else { return }
            MainActor.assumeIsolated {
                self.attach(to: window)
            }
        }
    }

    private nonisolated func isCanvasWindow(_ window: NSWindow) -> Bool {
        // The utility window has empty styleMask; the canvas window is titled.
        window.styleMask.contains(.titled)
    }

    private func attach(to parent: NSWindow) {
        guard let utility = utilityWindow else { return }
        if utility.parent === parent { return }
        parent.addChildWindow(utility, ordered: .below)
        if let observer = mainWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            mainWindowObserver = nil
        }
    }

    // MARK: - Setup

    /// Create the off-screen utility window and capture WKWebView.
    /// Window is positioned off-screen (not hidden — hidden windows get App Nap throttled).
    private func setupCaptureWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 1280, height: 800),
            styleMask: [],
            backing: .buffered,
            defer: false
        )

        let config = WebKitConfig.shared.makeConfiguration()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: config
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        window.contentView = webView
        window.orderFront(nil)

        self.utilityWindow = window
        self.captureWebView = webView
    }

    /// Recreate the capture WKWebView after a content process crash.
    private func recreateCaptureWebView() {
        captureWebView?.removeFromSuperview()
        captureWebView = nil

        let config = WebKitConfig.shared.makeConfiguration()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: config
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        utilityWindow?.contentView = webView
        self.captureWebView = webView
    }

    // MARK: - Public API

    /// Re-capture all routes with a single DOM-settle pass (lighter than full 3-pass).
    /// Used by the file watcher when source files change — pages are already hydrated
    /// so a single DOM-observer pass with a shorter timeout is sufficient.
    func recaptureAllRoutes() async {
        guard !AppServices.shared.demo.isInDemoMode else { return }
        guard !isCaptureInProgress else {
            print("[ScreenshotService] Capture already in progress, skipping re-capture")
            return
        }
        isCaptureInProgress = true

        let routes = document.routes
        print("[ScreenshotService] Re-capturing \(routes.count) routes (file change)")

        for route in routes {
            guard await waitWhilePaused() else { break }
            await captureRoute(route, settle: .domObserver(timeoutSeconds: 5))
        }

        isCaptureInProgress = false
        print("[ScreenshotService] Re-capture complete")
    }

    /// Three-tier capture: fast pass, then DOM-aware refinement, then fallback for stragglers.
    /// Pass `subset` to capture only those routes; nil/empty captures every route on the canvas.
    func captureAllRoutes(subset: [RouteFrame]? = nil) async {
        guard !isCaptureInProgress else {
            print("[ScreenshotService] Capture already in progress, skipping")
            return
        }
        isCaptureInProgress = true
        let routes = subset ?? document.routes
        let isSubset = subset != nil
        CrashReporter.shared.breadcrumb(
            category: "capture",
            action: "start",
            message: "\(routes.count) routes\(isSubset ? " (subset)" : "")"
        )

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Screenshot capture queue"
        )

        // --- Pass 1: Fast capture (readyState only, no extra delay) ---
        // Skip routes already captured by live view snapshots
        let uncapturedRoutes = routes.filter { document.screenshots[$0.id] == nil }
        print("[ScreenshotService] Pass 1 — fast capture of \(uncapturedRoutes.count) routes (\(routes.count - uncapturedRoutes.count) already cached)")
        for route in uncapturedRoutes {
            guard await waitWhilePaused() else { break }
            await captureRoute(route, settle: .none)
        }

        // --- Pass 2: DOM-aware refinement (MutationObserver, 10s timeout per route) ---
        print("[ScreenshotService] Pass 2 — DOM-aware refinement")
        var needsFallback: [RouteFrame] = []
        for route in uncapturedRoutes {
            guard await waitWhilePaused() else { break }
            let settled = await captureRoute(route, settle: .domObserver(timeoutSeconds: 10))
            if !settled {
                needsFallback.append(route)
            }
        }

        // --- Pass 3: Fixed delay fallback for routes that never settled ---
        if !needsFallback.isEmpty {
            print("[ScreenshotService] Pass 3 — fallback capture for \(needsFallback.count) routes")
            for route in needsFallback {
                guard await waitWhilePaused() else { break }
                await captureRoute(route, settle: .fixedDelay(seconds: 5))
            }
        }

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        CrashReporter.shared.breadcrumb(
            category: "capture",
            action: "complete",
            message: "\(routes.count) routes\(isSubset ? " (subset)" : "")"
        )
        isCaptureInProgress = false
        print("[ScreenshotService] All capture passes complete")
    }

    // MARK: - Canonical API (Stage 14.5a)

    /// Bind a Stage 13 `clientFrameId` to a canvas route. Stage 16a's Share
    /// Mode creates the UUID before first capture; Update Share keeps the same
    /// id so cache entries persist across re-uploads.
    func assignClientFrameId(routeID: UUID, clientFrameId: UUID) {
        clientFrameIds[routeID] = clientFrameId
    }

    /// Pre-share routes don't yet have a clientFrameId. Stage 16a's preview
    /// path mints one on the fly via this helper so the cache can key off a
    /// stable UUID immediately.
    func ensureClientFrameId(routeID: UUID) -> UUID {
        if let existing = clientFrameIds[routeID] { return existing }
        let fresh = UUID()
        clientFrameIds[routeID] = fresh
        return fresh
    }

    /// Set the `contentVersion` for a route's cache key. Stage 16b's finalise
    /// + update endpoints bump this; the cache lookup naturally drops stale
    /// entries because the key changes.
    func setContentVersion(routeID: UUID, contentVersion: Int) {
        contentVersions[routeID] = contentVersion
    }

    /// Canonical capture entry point. The stored `RouteFrame.captureDelay` is
    /// the only delay applied — callers CANNOT bypass it via a parameter.
    /// Stage 14.5b's auto-detect probe writes `captureDelay` on the route;
    /// the popover Done button also writes it. Share Mode (16a) + upload
    /// (16b) + MCP (20) all go through this method.
    @MainActor
    func capture(routeID: UUID, persist: Bool = true) async throws -> CaptureResult {
        guard let route = document.routes.first(where: { $0.id == routeID }) else {
            throw CaptureError.routeUnavailable
        }
        let delayMs = Int((route.captureDelay ?? 0) * 1000)
        return try await captureInternal(
            route: route,
            effectiveDelayMs: delayMs,
            persist: persist,
        )
    }

    /// Preview path. NEVER touches the cache; never mutates `RouteFrame`. Used
    /// by the popover Preview button (Stage 14.5b). The override is per-call.
    @MainActor
    func previewCapture(routeID: UUID, overrideDelayMs: Int) async throws -> CaptureResult {
        guard let route = document.routes.first(where: { $0.id == routeID }) else {
            throw CaptureError.routeUnavailable
        }
        return try await captureInternal(
            route: route,
            effectiveDelayMs: overrideDelayMs,
            persist: false,
        )
    }

    /// Cache-only lookup. Returns the most recent persisted capture for the
    /// route's stored delay + current contentVersion, or nil on miss. Used by
    /// Stage 16a's Share Mode preview card to read the existing capture
    /// before deciding whether to fire a fresh one.
    func cachedCapture(routeID: UUID) -> CaptureResult? {
        guard let route = document.routes.first(where: { $0.id == routeID }),
              let clientFrameId = clientFrameIds[routeID] else { return nil }
        let key = makeKey(
            clientFrameId: clientFrameId,
            viewport: CGSize(width: route.width, height: route.effectiveHeight),
            backingScale: backingScaleForCapture(),
            captureDelayMs: Int((route.captureDelay ?? 0) * 1000),
            routeID: routeID,
        )
        guard let entry = ScreenshotCache.shared.get(key) else { return nil }
        return CaptureResult(
            image: entry.image,
            cacheKey: key.digest,
            capturedAt: entry.capturedAt,
            contentVersion: key.contentVersion,
            fileURL: entry.fileURL,
        )
    }

    // MARK: - Canonical internal — Stage 14.5a step 2 algorithm

    private func captureInternal(
        route: RouteFrame,
        effectiveDelayMs: Int,
        persist: Bool,
    ) async throws -> CaptureResult {
        let token = (navigationTokens[route.id] ?? 0)
        let viewport = CGSize(width: route.width, height: route.effectiveHeight)
        let backingScale = backingScaleForCapture()

        // Wait for DOM-settle (10s timeout fallback). The existing 3-pass loop
        // performs its own settle separately; canonical callers (Share Mode,
        // upload, MCP) get a single explicit settle here.
        let settled = await settleCurrentPage(timeoutSeconds: 10)
        if Task.isCancelled { throw CaptureError.cancelled }

        // Custom delay AFTER DOM-settle.
        if effectiveDelayMs > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(effectiveDelayMs) * 1_000_000)
            } catch {
                throw CaptureError.cancelled
            }
        }

        // Navigation token check — if the WebView moved while we were waiting,
        // discard. Token may have been bumped by `webView(_:didStartProvisionalNavigation:)`.
        if (navigationTokens[route.id] ?? 0) != token {
            throw CaptureError.staleNavigation
        }
        _ = settled  // silence unused — kept for future probe hook

        guard let webView = captureWebView else {
            throw CaptureError.routeUnavailable
        }
        guard let image = await takeSnapshot(webView: webView, width: route.width) else {
            throw CaptureError.invalidImage
        }

        let clientFrameId = clientFrameIds[route.id] ?? ensureClientFrameId(routeID: route.id)
        let key = makeKey(
            clientFrameId: clientFrameId,
            viewport: viewport,
            backingScale: backingScale,
            captureDelayMs: effectiveDelayMs,
            routeID: route.id,
        )

        if persist {
            guard let fileURL = ScreenshotCache.shared.set(image: image, for: key) else {
                throw CaptureError.invalidImage
            }
            document.screenshots[route.id] = fileURL
            NotificationCenter.default.post(
                name: .screenshotDidUpdate,
                object: nil,
                userInfo: [
                    "routeID": route.id,
                    "cacheKey": key.digest,
                    "capturedAt": Date(),
                    "contentVersion": key.contentVersion,
                ],
            )
            return CaptureResult(
                image: image,
                cacheKey: key.digest,
                capturedAt: Date(),
                contentVersion: key.contentVersion,
                fileURL: fileURL,
            )
        }
        return CaptureResult(
            image: image,
            cacheKey: key.digest,
            capturedAt: Date(),
            contentVersion: key.contentVersion,
            fileURL: nil,
        )
    }

    private func makeKey(
        clientFrameId: UUID,
        viewport: CGSize,
        backingScale: CGFloat,
        captureDelayMs: Int,
        routeID: UUID,
    ) -> ScreenshotCache.Key {
        ScreenshotCache.Key(
            clientFrameId: clientFrameId,
            viewportW: Int(viewport.width),
            viewportH: Int(viewport.height),
            backingScale: Double(backingScale),
            captureDelayMs: captureDelayMs,
            contentVersion: contentVersions[routeID] ?? 0,
        )
    }

    private func backingScaleForCapture() -> CGFloat {
        utilityWindow?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
    }

    /// Convenience: run the existing DOM-settle helper against the current
    /// `captureWebView`. Returns the settled flag (true = settled, false = timeout).
    private func settleCurrentPage(timeoutSeconds: Int) async -> Bool {
        guard let webView = captureWebView else { return false }
        return await waitForDOMStable(webView: webView, timeoutSeconds: timeoutSeconds)
    }

    /// Capture a single route and update the document model.
    /// Returns true if the page settled (DOM stable), false if it timed out.
    @discardableResult
    func captureRoute(_ route: RouteFrame, settle: SettleStrategy = .domObserver(timeoutSeconds: 10)) async -> Bool {
        guard let webView = captureWebView else { return false }

        guard let url = document.url(for: route) else {
            print("[ScreenshotService] Invalid URL for route: \(route.path)")
            return false
        }
        let routePath = cleanPath(route.path)

        // Resize capture webview to match route dimensions
        let captureW = route.width
        let captureH = route.effectiveHeight
        webView.frame = NSRect(x: 0, y: 0, width: captureW, height: captureH)
        utilityWindow?.setContentSize(NSSize(width: captureW, height: captureH))

        // Per-phase timings — exposes whether nav, ready, settle, or snapshot dominate.
        let totalStart = Date()

        // Load URL and wait for navigation to finish
        let navStart = Date()
        webView.load(URLRequest(url: url))
        let didLoad = await waitForNavigation(webView: webView)
        let navMs = Int(Date().timeIntervalSince(navStart) * 1000)
        guard didLoad else {
            print("[ScreenshotService] [\(settle.label)] \(routePath) FAILED nav after \(navMs)ms")
            return false
        }

        // Wait for page readiness (JS probe — handles SPA hydration)
        let readyStart = Date()
        await waitForReady(webView: webView)
        let readyMs = Int(Date().timeIntervalSince(readyStart) * 1000)

        // Apply settle strategy
        let settleStart = Date()
        var didSettle = true
        switch settle {
        case .none:
            break
        case .domObserver(let timeoutSeconds):
            didSettle = await waitForDOMStable(webView: webView, timeoutSeconds: timeoutSeconds)
            if !didSettle {
                print("[ScreenshotService] [\(routePath)] DOM did NOT settle within \(timeoutSeconds)s")
            }
        case .fixedDelay(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        }
        let settleMs = Int(Date().timeIntervalSince(settleStart) * 1000)

        // Diagnostic: log page state at capture time
        await logPageState(webView: webView, route: routePath, pass: settle.label)

        // Inject white background (JPEG doesn't support transparency — would render black)
        await injectWhiteBackground(webView: webView)

        // Take snapshot
        let snapStart = Date()
        guard let image = await takeSnapshot(webView: webView, width: captureW) else {
            print("[ScreenshotService] Snapshot failed for \(routePath)")
            return didSettle
        }
        let snapMs = Int(Date().timeIntervalSince(snapStart) * 1000)

        // Save to disk as JPEG
        guard let fileURL = saveScreenshot(image, for: route) else {
            print("[ScreenshotService] Failed to save screenshot for \(routePath)")
            return didSettle
        }

        // Update document model
        document.screenshots[route.id] = fileURL
        let totalMs = Int(Date().timeIntervalSince(totalStart) * 1000)
        let pass = settle.label
        print("[ScreenshotService] [\(pass)] \(routePath) -> \(fileURL.lastPathComponent) (nav=\(navMs)ms ready=\(readyMs)ms settle=\(settleMs)ms snap=\(snapMs)ms total=\(totalMs)ms)")
        return didSettle
    }

    // MARK: - Settle strategies

    enum SettleStrategy {
        case none                          // Pass 1: capture immediately after readyState
        case domObserver(timeoutSeconds: Int) // Pass 2: wait for DOM to stop mutating
        case fixedDelay(seconds: Int)      // Pass 3: fallback fixed delay

        var label: String {
            switch self {
            case .none: return "fast"
            case .domObserver: return "DOM"
            case .fixedDelay: return "fallback"
            }
        }
    }

    // MARK: - Navigation waiting

    private var navigationContinuation: CheckedContinuation<Bool, Never>?

    private func waitForNavigation(webView: WKWebView, timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            self.navigationContinuation = continuation
            // Safety timeout — if navigation never fires a delegate callback, unblock the pipeline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.navigationContinuation != nil else { return }
                print("[ScreenshotService] Navigation timed out after \(Int(timeout))s")
                self.navigationContinuation?.resume(returning: false)
                self.navigationContinuation = nil
            }
        }
    }

    // MARK: - JS readiness probe

    /// Poll document.readyState every 200ms, max 3 seconds.
    private func waitForReady(webView: WKWebView) async {
        for _ in 0..<15 {
            let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete'")
            if ready as? Bool == true { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - DOM MutationObserver settle detection

    /// Inject a MutationObserver that resolves when the DOM has been stable for 500ms.
    /// Returns true if DOM settled, false if it hit the timeout (page never stopped mutating).
    private func waitForDOMStable(webView: WKWebView, timeoutSeconds: Int) async -> Bool {
        let js = """
        new Promise(function(resolve) {
            var timer = null;
            var settled = false;
            var observer = new MutationObserver(function() {
                clearTimeout(timer);
                timer = setTimeout(function() {
                    settled = true;
                    observer.disconnect();
                    resolve(true);
                }, 500);
            });
            observer.observe(document.documentElement, {
                childList: true, subtree: true, attributes: true, characterData: true
            });
            // Start the initial timer — if nothing mutates at all, settle after 500ms
            timer = setTimeout(function() {
                settled = true;
                observer.disconnect();
                resolve(true);
            }, 500);
            // Hard timeout — resolve false if DOM never settles
            setTimeout(function() {
                if (!settled) {
                    observer.disconnect();
                    resolve(false);
                }
            }, \(timeoutSeconds * 1000));
        });
        """

        let result = try? await webView.callAsyncJavaScript(
            js,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        return result as? Bool ?? false
    }

    // MARK: - Diagnostics

    /// Log page state at capture time — helps debug pages that appear blank.
    private func logPageState(webView: WKWebView, route: String, pass: String) async {
        let js = """
        (function() {
            var body = document.body;
            var docEl = document.documentElement;
            return {
                url: window.location.href,
                readyState: document.readyState,
                bodyChildren: body ? body.children.length : 0,
                bodyScrollH: body ? body.scrollHeight : 0,
                bodyText: body ? body.innerText.substring(0, 200) : '(no body)',
                docScrollH: docEl ? docEl.scrollHeight : 0,
                images: document.images.length,
                imagesLoaded: Array.from(document.images).filter(function(i) { return i.complete; }).length
            };
        })()
        """
        if let result = try? await webView.evaluateJavaScript(js) as? [String: Any] {
            let bodyChildren = result["bodyChildren"] ?? "?"
            let bodyScrollH = result["bodyScrollH"] ?? "?"
            let docScrollH = result["docScrollH"] ?? "?"
            let images = result["images"] ?? "?"
            let imagesLoaded = result["imagesLoaded"] ?? "?"
            let bodyText = (result["bodyText"] as? String)?.prefix(100) ?? "?"
            print("[ScreenshotService] [\(pass)] \(route): children=\(bodyChildren) bodyH=\(bodyScrollH) docH=\(docScrollH) imgs=\(images)/\(imagesLoaded) text=\"\(bodyText)\"")
        }
    }

    // MARK: - White background injection

    private func injectWhiteBackground(webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript(
            "document.body.style.backgroundColor = '#FFFFFF'"
        )
    }

    // MARK: - Snapshot

    private func takeSnapshot(webView: WKWebView, width: CGFloat) async -> NSImage? {
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.snapshotWidth = NSNumber(value: Double(width))

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfig) { image, error in
                if let error {
                    print("[ScreenshotService] Snapshot error: \(error.localizedDescription)")
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Save to disk

    private func saveScreenshot(_ image: NSImage, for route: RouteFrame) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }

        let filename = sanitizeFilename(route.path) + "_\(route.id.uuidString.prefix(8)).jpg"
        let fileURL = Self.screenshotDir.appendingPathComponent(filename)

        do {
            try jpegData.write(to: fileURL)
            return fileURL
        } catch {
            print("[ScreenshotService] Write error: \(error.localizedDescription)")
            return nil
        }
    }

    private func sanitizeFilename(_ path: String) -> String {
        let cleaned = cleanPath(path)
        if cleaned == "/" { return "root" }
        return cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
    }

    private func cleanPath(_ path: String) -> String {
        if let parenRange = path.range(of: " (") {
            return String(path[path.startIndex..<parenRange.lowerBound])
        }
        return path
    }
}

// MARK: - WKNavigationDelegate (for capture webview only)

extension ScreenshotService: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Stage 14.5a — bump the navigation token for whichever route is currently
        // staged on the capture WebView. Pending captures detect the bump in their
        // step-4 token check and discard rather than commit stale bitmaps.
        Task { @MainActor in
            for (routeID, token) in navigationTokens {
                navigationTokens[routeID] = token + 1
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navigationContinuation?.resume(returning: true)
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[ScreenshotService] Navigation failed: \(error.localizedDescription)")
            navigationContinuation?.resume(returning: false)
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[ScreenshotService] Provisional navigation failed: \(error.localizedDescription)")
            navigationContinuation?.resume(returning: false)
            navigationContinuation = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            print("[ScreenshotService] Content process terminated, recreating capture webview")
            navigationContinuation?.resume(returning: false)
            navigationContinuation = nil
            recreateCaptureWebView()
        }
    }
}
