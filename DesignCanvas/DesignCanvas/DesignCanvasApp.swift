// App entry point — launches a single window with the infinite canvas.
// Stage 6: starts HTTP API server on localhost:7420 for external tool control.
// Stage 7: spawns/connects to dev server process, project picker UI.
// Stage 9: file watcher auto-refreshes screenshots when source files change.
// Stage 10: auto-load root route, floating toolbar, zoom indicator, empty state.

import SwiftUI
import Observation

/// Observable demo state — separated from AppServices to avoid @Observable
/// on the container class (which breaks nested onChange tracking).
@Observable
@MainActor
class DemoState {
    var isInDemoMode: Bool = false
    var demoDetectedServers: [DetectedServer] = []
}

/// Shared state container — services that need to exist before the window appears.
/// Created eagerly by AppDelegate, consumed by the SwiftUI view.
@Observable
@MainActor
class AppServices {
    static let shared = AppServices()

    let document = DocumentModel()
    let camera = CanvasCamera()
    let interactionRouter = InteractionRouter()
    let interactHintCoordinator = InteractHintCoordinator()
    let devServer = DevServerManager()
    let routeDiscovery = RouteDiscovery()
    let paletteState = CommandPaletteState()
    let terminalCommands = TerminalCommandsStore()
    let workspaceFileIndex = WorkspaceFileIndex()
    let markdownPathHealer = MarkdownPathHealer()
    let sessionPersistence = SessionPersistence()
    let portScanner = PortScanner()
    let switcherState = WorkspaceSwitcherState()
    let newServerDetector = NewServerDetector()
    let mcpState = MCPConnectionState()
    let onboarding = OnboardingCardState()
    let mcpActivity = MCPActivityDetector()
    let claudeAccounts = ClaudeAccountsManager()
    /// Back-compat alias for the primary account (account 1). Existing call sites
    /// (menu commands, etc.) keep working; the manager owns the full account set.
    var claudeUsage: ClaudeUsageService { claudeAccounts.primaryAccount }
    let openAIUsage = OpenAIUsageService()
    let stormDetector = ReloadStormDetector()
    let devServerRegistry: DevServerRegistry
    /// Stage 16a — Share Mode lifecycle. The coordinator's session-scoped
    /// CaptureOrchestrator is rebuilt on each `enter()`.
    let shareMode = ShareModeCoordinator()

    init() {
        self.devServerRegistry = DevServerRegistry(document: document)
        stormDetector.onEnterPaused = { [weak self] in self?.handleStormEnteredPaused() }
        stormDetector.onResume = { [weak self] reload in self?.handleStormResumed(reloadFrames: reload) }
        stormDetector.onForceRefresh = { [weak self] in self?.handleStormForceRefresh() }
    }

    /// One-shot guard: when the demo → live handoff fires, skip the welcome box
    /// on the next `.running` transition so Peter doesn't get it mid-demo exit.
    var skipWelcomeOnNextRunningTransition: Bool = false

    /// Set by URL handler when the app is launched from a share link.
    var isShareLinkSession: Bool = false

    private static let lastProjectDirKey = "lastActiveProjectDir"

    private(set) var screenshotService: ScreenshotService?
    private(set) var canvasManager: CanvasManager?
    private(set) var httpServer: HTTPAPIServer?
    private(set) var fileWatcher: FileWatcher?

    /// Whether the root route was auto-loaded on first server detection.
    var didAutoLoadRoot = false

    /// Demo state — observable, separated to avoid @Observable on AppServices.
    let demo = DemoState()

    /// Re-run route discovery and merge results. Called by 404 fallback detection
    /// to validate whether a route's source file still exists on disk.
    func triggerRouteDiscovery() {
        guard let projectDir = sessionPersistence.currentProjectDir else { return }
        let projectURL = URL(fileURLWithPath: projectDir)
        let discovered = routeDiscovery.discoverRoutes(projectDir: projectURL)
        document.mergeDiscoveredRoutes(discovered)
    }

    func startHTTPServer() {
        guard httpServer == nil else { return }
        let service = ScreenshotService(document: document)
        screenshotService = service
        let manager = CanvasManager(document: document, screenshotService: service)
        canvasManager = manager
        let server = HTTPAPIServer(canvasManager: manager, mcpState: mcpState, mcpActivity: mcpActivity)
        httpServer = server
        server.start()
    }

    /// Capture screenshots for routes that don't have cached images yet.
    /// Called reactively after live views finish loading, not eagerly on launch.
    func captureUncachedScreenshots() {
        guard let service = screenshotService else { return }
        guard !service.isCaptureInProgress else { return }
        guard !demo.isInDemoMode else { return }  // Don't re-capture demo screenshots
        // Only run when no live views are loading
        let hasUncached = document.routes.contains { document.screenshots[$0.id] == nil }
        guard hasUncached else { return }
        Task {
            await service.captureAllRoutes()
        }
    }

    /// Smart launch — quick scan, instant demo if nothing found, periodic scan continues.
    func smartLaunch() {
        if ProcessInfo.processInfo.environment["DESIGN_CANVAS_DEMO"] == "1" {
            demo.isInDemoMode = true
            document.loadDemoRoutes()
            return
        }
        let hasSavedSessions = sessionPersistence.listAll().count > 0

        Task {
            // Phase 1: TCP probe only (~50ms — no lsof shell-out).
            // Project dirs enrich asynchronously and update the workspace switcher labels.
            let placeholders = await portScanner.quickProbe()

            if placeholders.count == 1 {
                // Single live server — connect immediately. lastDir matching is moot
                // when there's only one option.
                let server = placeholders[0]
                print("[SmartLaunch] Single server on port \(server.port), connecting…")
                devServer.connect(port: server.port)
            } else if placeholders.count > 1 {
                // Multiple — need projectDir to apply lastDir match. Await full enrichment.
                let enriched = await portScanner.fullScanAwait()
                let lastDir = UserDefaults.standard.string(forKey: Self.lastProjectDirKey)
                if let lastDir, let match = enriched.first(where: { $0.projectDir == lastDir }) {
                    print("[SmartLaunch] Restoring last project: \(match.projectName) :\(match.port)")
                    devServer.connect(port: match.port)
                } else {
                    let server = enriched[0]
                    print("[SmartLaunch] Multiple servers, picking first: \(server.projectName) :\(server.port)")
                    devServer.connect(port: server.port)
                }
            } else if !hasSavedSessions {
                // No servers found, no saved sessions → load demo
                demo.isInDemoMode = true
                document.loadDemoRoutes()
                AnalyticsService.shared.capture(.demoModeStarted)
                print("[SmartLaunch] No servers, no history — demo loaded")

                // Faster re-scan during demo — check every 5s until a server appears
                Task { [weak self] in
                    guard let self else { return }
                    print("[Demo] Starting fast scan loop")
                    while self.demo.isInDemoMode {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard self.demo.isInDemoMode else { break }
                        self.portScanner.scanNow()
                        // Wait for scan to complete, then sync to demoDetectedServers
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard self.demo.isInDemoMode else { break }
                        let found = self.portScanner.detectedServers
                        self.demo.demoDetectedServers = found
                        if !found.isEmpty {
                            print("[Demo] Servers detected: \(found.map { "\($0.projectName):\($0.port)" })")
                        }
                    }
                    print("[Demo] Fast scan loop ended")
                }
            } else {
                // Returning user with saved sessions, no server running
                print("[SmartLaunch] No servers found, waiting…")
                devServer.connect(port: 3000)
            }

            // Phase 2: Start periodic scanning for future server detection
            portScanner.startPeriodicScan()
        }
    }

    /// Save the last active project directory for smart launch on next open.
    func saveLastActiveProject(_ dir: String) {
        UserDefaults.standard.set(dir, forKey: Self.lastProjectDirKey)
    }

    /// Start watching a project directory for file changes.
    /// On source file changes: re-capture screenshots (coarse invalidation).
    /// On page file changes: re-run route discovery to add/remove routes.
    func startFileWatcher(projectDir: String) {
        fileWatcher?.stop()
        let watcher = FileWatcher(watchPath: projectDir)

        watcher.onSourceFilesChanged = { [weak self] in
            guard let self else { return }
            print("[FileWatcher] Source files changed — re-capturing screenshots")
            Task {
                await self.screenshotService?.recaptureAllRoutes()
            }
        }

        watcher.onPageFilesChanged = { [weak self] in
            guard let self else { return }
            print("[FileWatcher] Page files changed — re-running route discovery")
            let projectURL = URL(fileURLWithPath: projectDir)
            let discovered = self.routeDiscovery.discoverRoutes(projectDir: projectURL)
            self.document.mergeDiscoveredRoutes(discovered)
        }

        watcher.onDocumentFilesChanged = { [weak self] changedPaths in
            guard let self else { return }
            Task { @MainActor in
                // Drop the workspace index so the next palette open re-walks the tree.
                self.workspaceFileIndex.invalidate()

                // Normalize both sides via resolvingSymlinksInPath. WorkspaceFileIndex stores
                // resolved paths on the document; FSEvents may emit unresolved ones (e.g. /var
                // vs /private/var, or worktree symlinks), so the raw Set.contains check
                // would silently miss matches and skip the reload.
                let normalizedChanged = Set(changedPaths.map { ($0 as NSString).resolvingSymlinksInPath })
                let affected = self.document.documents.filter {
                    normalizedChanged.contains(($0.filePath as NSString).resolvingSymlinksInPath)
                }
                guard !affected.isEmpty else { return }

                // Heal step: any frame whose stored path no longer exists is a candidate
                // for path-rewrite via basename + content-hash match. A rename within the
                // project root surfaces here as the *old* path being touched (the delete
                // event); the *new* path arrives in the same debounced burst as a create.
                var healedIds: Set<UUID> = []
                let missing = affected.filter {
                    !FileManager.default.fileExists(atPath: $0.filePath)
                }
                if !missing.isEmpty {
                    let needles = missing.map {
                        MarkdownPathHealer.MissingFrame(id: $0.id, filePath: $0.filePath)
                    }
                    let resolutions = await self.markdownPathHealer.heal(
                        missingFrames: needles, projectDir: projectDir
                    )
                    for r in resolutions {
                        guard self.document.updateDocumentPath(id: r.frameId, newPath: r.newPath) else { continue }
                        healedIds.insert(r.frameId)
                        let oldName = (r.oldPath as NSString).lastPathComponent
                        let newName = (r.newPath as NSString).lastPathComponent
                        print("[MarkdownPathHealer] \(oldName) → \(r.newPath) (hash=\(r.usedHash))")
                        CrashReporter.shared.breadcrumb(
                            category: "canvas", action: "doc_healed",
                            message: "\(oldName) → \(newName)"
                        )
                        // Refresh the cache against the new file so the next move heals too.
                        self.markdownPathHealer.recordHash(frameId: r.frameId, filePath: r.newPath)
                    }
                    if !healedIds.isEmpty {
                        self.sessionPersistence.scheduleSave(
                            document: self.document, port: self.devServer.port
                        )
                    }
                }

                // Reload frames whose content changed. Healed frames are re-attached via
                // the @Observable update(markdown:) path-changed branch — calling reload()
                // here with the still-stale routePath would briefly flash the error overlay.
                let toReload = affected.map(\.id).filter { !healedIds.contains($0) }
                guard !toReload.isEmpty else { return }
                print("[FileWatcher] \(toReload.count) markdown frame(s) to reload")
                self.reloadContainersMatching(ids: Set(toReload))
            }
        }

        watcher.onImageFilesChanged = { [weak self] changedPaths in
            guard let self else { return }
            Task { @MainActor in
                let normalizedChanged = Set(changedPaths.map { ($0 as NSString).resolvingSymlinksInPath })
                let affected = self.document.images.filter {
                    normalizedChanged.contains(($0.filePath as NSString).resolvingSymlinksInPath)
                }
                guard !affected.isEmpty else { return }
                print("[FileWatcher] \(affected.count) image frame(s) to reload")
                self.reloadContainersMatching(ids: Set(affected.map(\.id)))
            }
        }

        watcher.start()
        fileWatcher = watcher
    }

    /// Find CanvasFrameContainers whose id is in `ids` and call reload() on each.
    /// Walks every window's content view for the canvas document view.
    @MainActor
    private func reloadContainersMatching(ids: Set<UUID>) {
        for window in NSApplication.shared.windows {
            guard let docView = findCanvasDocumentView(in: window.contentView) else { continue }
            let containers = docView.subviews.compactMap { $0 as? CanvasFrameContainer }
            for c in containers where ids.contains(c.routeId) {
                c.reload()
            }
        }
    }

    /// Walk all live `CanvasFrameContainer`s and call the given action on each.
    /// Used by the dev-server status transitions to show/hide the "server unreachable" overlay.
    @MainActor
    private func forEachLiveContainer(_ action: (CanvasFrameContainer) -> Void) {
        for window in NSApplication.shared.windows {
            guard let docView = findCanvasDocumentView(in: window.contentView) else { continue }
            for c in docView.subviews.compactMap({ $0 as? CanvasFrameContainer }) {
                action(c)
            }
        }
    }

    /// Show the "server unreachable" overlay on every live frame. Called when the
    /// dev-server monitor flips status to `.disconnected` while routes are loaded.
    @MainActor
    func markLiveFramesServerUnreachable() {
        forEachLiveContainer { $0.showError("Server unreachable — restart your dev server") }
    }

    /// Clear the "server unreachable" overlay and reload each live frame. Called
    /// when the dev server reappears (status flips back to `.running`).
    @MainActor
    func reloadAllLiveFrames() {
        forEachLiveContainer {
            $0.hideError()
            $0.reload()
        }
    }

    /// Phase D — reload only the live frames belonging to a given binding. Used after
    /// a port rebind so the WKWebViews pick up the new origin URL without disturbing
    /// frames attached to other bindings.
    @MainActor
    func reloadFramesForBinding(_ bindingId: UUID) {
        let affected = Set(document.routes.filter { $0.serverBindingId == bindingId }.map(\.id))
        forEachLiveContainer { container in
            guard affected.contains(container.routeId) else { return }
            container.hideError()
            container.reload()
        }
    }

    // MARK: - Reload-storm orchestration (wired in init)

    /// Storm entered: stop in-flight loads and refresh visual state on every
    /// live route container. The accent halo appears via `applyVisualState`.
    @MainActor
    private func handleStormEnteredPaused() {
        forEachLiveContainer { container in
            guard container.kind == .route else { return }
            let state = container.tileLifecycle?.frameStates[container.routeId]
            if state == .live || state == .loadingLive {
                container.webView?.stopLoading()
            }
            container.applyVisualState()
        }
    }

    /// Storm resolved (auto or manual ▶): refresh visual state, then optionally
    /// trigger one catch-up reload per live route container.
    @MainActor
    private func handleStormResumed(reloadFrames: Bool) {
        forEachLiveContainer { container in
            container.applyVisualState()
            guard reloadFrames, container.kind == .route else { return }
            let state = container.tileLifecycle?.frameStates[container.routeId]
            if state == .live || state == .loadingLive {
                container.webView?.reload()
            }
        }
    }

    /// Card ↻ / toolbar ↻: reload every live frame + recapture screenshots.
    /// Pause state is left to the caller (toolbar resumes on top of this; card peek does not).
    @MainActor
    private func handleStormForceRefresh() {
        reloadAllLiveFrames()
        Task { await screenshotService?.recaptureAllRoutes() }
    }

    @MainActor
    private func findCanvasDocumentView(in view: NSView?) -> CanvasDocumentView? {
        guard let view else { return nil }
        if let match = view as? CanvasDocumentView { return match }
        for sub in view.subviews {
            if let match = findCanvasDocumentView(in: sub) { return match }
        }
        return nil
    }

    /// Stop and release the file watcher.
    func stopFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    /// Open a project directory and spawn dev server.
    /// Route discovery is triggered reactively via onChange(of: projectDir) in the App body.
    func openProject(directory: String, port: Int = 3000) {
        devServer.startServer(projectDir: directory, port: port)
    }

    /// Auto-load the root route "/" as the first frame on the canvas.
    /// Called when a dev server is detected and no routes are on canvas yet.
    func autoLoadRoot() {
        guard document.routes.isEmpty, !didAutoLoadRoot else { return }
        didAutoLoadRoot = true
        _ = try? canvasManager?.addRoute(
            path: "/",
            x: CanvasCamera.canvasCenter.x - 640,
            y: CanvasCamera.canvasCenter.y - 400,
            width: 1280,
            height: 800
        )
        print("[Stage10] Auto-loaded root route /")
    }
}

@main
struct DesignCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(BuildPolicy.accountIntegrationKey) private var accountIntegrationsEnabled = false
    @StateObject private var updaterManager = UpdaterManager()
    @State private var showRouteBanner = false
    @State private var showConnectedToast = false
    /// Which account's claude.ai login sheet to present, if any. Drives a
    /// `.sheet(item:)` so account 1 and account 2 can each open their own login.
    @State private var loginSheetAccount: ClaudeUsageService?
    @State private var isDevServerPopoverPresented = false
    @State private var isCanvasSwitcherPresented = false

    // C0 + D — rebind toast state. One candidate at a time; dismissed bindings
    // are not surfaced again this session.
    @State private var pendingRebindCandidate: PortRebindCandidate?
    @State private var dismissedRebindBindingIds: Set<UUID> = []

    private var services: AppServices { AppServices.shared }

    private var canvasBaseContent: some View {
            ZStack(alignment: .topLeading) {
                CanvasContainerView(
                    camera: services.camera,
                    document: services.document,
                    interactionRouter: services.interactionRouter,
                    interactHintCoordinator: services.interactHintCoordinator,
                    isInDemoMode: services.demo.isInDemoMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Canvas chip + route banner — top-left corner. The chip names the artifact;
                // server-switching moved to the right-side DevServerPill. Tapping opens the
                // canvas switcher dropdown (A1).
                VStack(alignment: .leading, spacing: 6) {
                    CanvasChip(
                        name: services.document.activeCanvas.name,
                        onTap: { isCanvasSwitcherPresented.toggle() }
                    )
                    .popover(isPresented: $isCanvasSwitcherPresented, arrowEdge: .bottom) {
                        CanvasSwitcher(
                            document: services.document,
                            onSwitchCanvas: { id in switchCanvas(to: id) },
                            onCreateCanvas: { createNewCanvas() },
                            onRenameCanvas: { canvas in renameCanvas(canvas) },
                            onDuplicateCanvas: { canvas in duplicateCanvas(canvas) },
                            onDeleteCanvas: { canvas in deleteCanvas(canvas) },
                            onDismiss: { isCanvasSwitcherPresented = false }
                        )
                    }

                    if showRouteBanner {
                        RouteSuggestionBanner(
                            addableCount: addableRouteCount,
                            onAdd: { addSuggestedRoutes() },
                            onDismiss: { dismissRouteBanner() }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if services.stormDetector.isPaused {
                        PausedStatusCard(detector: services.stormDetector)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 12)
                .animation(.easeInOut(duration: 0.25), value: showRouteBanner)
                .animation(.easeInOut(duration: 0.25), value: services.stormDetector.isPaused)
            }
            // Empty state overlay — shown when canvas has no routes (not during demo)
            .overlay {
                if services.document.routes.isEmpty && !services.demo.isInDemoMode {
                    EmptyStateView(
                        serverRunning: services.devServer.status == .running,
                        onOpenMCPSetup: { services.mcpState.open() }
                    )
                }
            }
            // Floating toolbar — bottom centre, hidden while demo panel / welcome box show.
            // Stage 16a: dimmed + un-interactive while Share Mode is active so the
            // mode's top-right action cluster is the only entry point.
            .overlay(alignment: .bottom) {
                if !showsBottomCenterOnboarding && !services.demo.isInDemoMode {
                    FloatingToolbar(
                        camera: services.camera,
                        document: services.document,
                        mcpState: services.mcpState
                    )
                    .padding(.bottom, 24)
                    .opacity(services.shareMode.state == .active ? 0.35 : 1.0)
                    .allowsHitTesting(services.shareMode.state != .active)
                    .animation(.easeInOut(duration: 0.15), value: services.shareMode.state)
                }
            }
            // Stage 16a — Share Mode overlay. Renders accent border, top-left pill,
            // top-right action cluster, bottom-right recipient preview when state ≠ .inactive.
            .overlay {
                if services.shareMode.state != .inactive {
                    ShareModeWindow(coordinator: services.shareMode)
                        .allowsHitTesting(true)
                }
            }
            // Stage 16a — post-exit share chip; only after a successful Create Link.
            .overlay(alignment: .topTrailing) {
                if services.shareMode.state == .inactive,
                   case .copied = services.shareMode.createLinkState {
                    PostExitShareChip(coordinator: services.shareMode)
                        .padding(.top, 60)
                        .padding(.trailing, 16)
                }
            }
    }

    private var canvasVisualContent: some View {
        canvasBaseContent
            // Top-right chrome — dev-server pill + Claude pill, side by side. The dev-server
            // pill replaces today's top-left workspace chip; the auto-detect "new server"
            // toast slides in directly under the pill row so the user reads top-to-bottom.
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        DevServerPill(
                            devServer: services.devServer,
                            isInDemoMode: services.demo.isInDemoMode,
                            demoDetectedServers: services.demo.demoDetectedServers,
                            onTap: {
                                if services.demo.isInDemoMode && services.demo.demoDetectedServers.count == 1 {
                                    exitDemoMode(connectToPort: services.demo.demoDetectedServers[0].port)
                                } else {
                                    isDevServerPopoverPresented = true
                                }
                            }
                        )
                        .popover(isPresented: $isDevServerPopoverPresented, arrowEdge: .top) {
                            DevServerPillPopover(
                                boundServers: services.document.bindings,
                                detectedServers: services.portScanner.detectedServers,
                                primaryBindingId: services.document.primaryBindingId,
                                activePort: services.devServer.status == .running ? services.devServer.port : nil,
                                isInDemoMode: services.demo.isInDemoMode,
                                onSelectBoundServer: { binding in
                                    // C0: selecting a bound server marks it primary for new
                                    // routes. If the primary controller isn't pointed at this
                                    // binding's projectDir yet, switching is what the user
                                    // wants (it triggers the session-switch path).
                                    if let dir = binding.projectDir,
                                       dir != services.devServer.projectDir,
                                       let port = binding.port {
                                        switchToPort(port)
                                    } else {
                                        services.document.primaryBindingId = binding.id
                                    }
                                },
                                onBindDetectedServer: { server in
                                    if services.demo.isInDemoMode {
                                        exitDemoMode(connectToPort: server.port)
                                    } else if services.document.bindings.isEmpty {
                                        switchToPort(server.port)
                                    } else {
                                        Task { await services.devServerRegistry.bind(port: server.port) }
                                    }
                                },
                                onConnectToPort: { port in
                                    if services.demo.isInDemoMode {
                                        exitDemoMode(connectToPort: port)
                                    } else if services.document.bindings.isEmpty {
                                        switchToPort(port)
                                    } else {
                                        Task { await services.devServerRegistry.bind(port: port) }
                                    }
                                },
                                onUnbindServer: { binding in
                                    // Remove the binding + drop routes that pointed at it.
                                    // Routes' screenshots stay on disk; user can re-bind later.
                                    services.document.routes.removeAll { $0.serverBindingId == binding.id }
                                    services.document.bindings.removeAll { $0.id == binding.id }
                                    if services.document.primaryBindingId == binding.id {
                                        services.document.primaryBindingId = services.document.bindings.first?.id
                                    }
                                },
                                onSwitchToDemo: { enterDemoMode() },
                                onDismiss: { isDevServerPopoverPresented = false }
                            )
                        }

                        // One pill per tracked Claude account (account 1, then a
                        // second account if added). Extracted to a computed view to
                        // keep the Scene body within the type-checker's budget.
                        claudeUsagePills
                    }

                    if services.newServerDetector.isVisible {
                        NewServerToast(
                            detector: services.newServerDetector,
                            onSwitch: { server in
                                // C0: if any bindings exist, this toast represents
                                // "another dev server is up — want to plug it in?" — bind
                                // it. Pre-binding (empty document) the same flow becomes
                                // the primary connect.
                                if services.document.bindings.isEmpty {
                                    switchToPort(server.port)
                                } else {
                                    Task { await services.devServerRegistry.bind(port: server.port) }
                                }
                            }
                        )
                    }

                    if let candidate = pendingRebindCandidate {
                        PortRebindToast(
                            candidate: candidate,
                            onRebind: { applyRebind(candidate) },
                            onIgnore: {
                                dismissedRebindBindingIds.insert(candidate.id)
                                pendingRebindCandidate = nil
                            }
                        )
                    }
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
            // Zoom indicator — bottom right
            .overlay(alignment: .bottomTrailing) {
                ZoomIndicator(camera: services.camera)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
            }
            // Interact hint toast
            .overlay(alignment: .bottom) {
                if services.interactHintCoordinator.isVisible {
                    InteractHintToast(coordinator: services.interactHintCoordinator)
                        .padding(.bottom, 48)
                }
            }
            // Command palette overlay
            .overlay {
                if services.paletteState.isOpen {
                    CommandPalette(state: services.paletteState)
                }
            }
            // Workspace switcher overlay
            .overlay {
                if services.switcherState.isOpen {
                    WorkspaceSwitcher(
                        state: services.switcherState,
                        onSelectRunning: { server in
                            if services.demo.isInDemoMode {
                                exitDemoMode(connectToPort: server.port)
                            } else {
                                switchToPort(server.port)
                            }
                        },
                        onSelectRecent: { saved in
                            if services.demo.isInDemoMode {
                                let port = services.switcherState.resolvePort(for: saved) ?? saved.serverPort
                                exitDemoMode(connectToPort: port)
                            } else if let port = services.switcherState.resolvePort(for: saved) {
                                switchToPort(port)
                            } else {
                                services.devServer.setProjectDir(saved.projectDir)
                                switchToPort(saved.serverPort)
                            }
                        },
                        onConnectToPort: { port in
                            if services.demo.isInDemoMode {
                                exitDemoMode(connectToPort: port)
                            } else {
                                switchToPort(port)
                            }
                        },
                        onSetupMCP: {
                            services.onboarding.send(
                                .openPasteModal(
                                    source: .keyboardShortcut,
                                    hasLiveRoutes: services.document.routes.count > 0
                                )
                            )
                        }
                    )
                }
            }
            // MCP setup sheet
            .overlay {
                if services.mcpState.isSheetOpen {
                    MCPSetupSheet(state: services.mcpState)
                }
            }
            // Claude usage login sheet
            .sheet(item: $loginSheetAccount) { account in
                ClaudeLoginSheet(service: account)
            }
            // MCP nudge toast — delayed, shown once (deprecated by onboarding card but kept for now)
            .overlay(alignment: .bottom) {
                if services.mcpState.isNudgeVisible {
                    MCPNudgeToast(mcpState: services.mcpState)
                        .padding(.bottom, 72)
                }
            }
            // Onboarding base surfaces — centre-bottom demo panel or welcome box.
            .overlay(alignment: .bottom) {
                switch services.onboarding.basePhase {
                case .demoPanel:
                    DemoConnectPanel {
                        services.onboarding.send(
                            .openPasteModal(source: .demoPanel, hasLiveRoutes: false)
                        )
                    }
                    .padding(.bottom, 24)
                case .devServerWelcome:
                    DevServerWelcomeBox(
                        onClose: { services.onboarding.send(.tapCloseWelcome) },
                        onInstallPlugin: {
                            services.onboarding.send(
                                .openPasteModal(
                                    source: .devServerWelcome,
                                    hasLiveRoutes: services.document.routes.count > 0
                                )
                            )
                        }
                    )
                    .padding(.bottom, 24)
                default:
                    EmptyView()
                }
            }
            // Paste modal — centred overlay, Esc / click-outside dismiss
            .overlay {
                if services.onboarding.isPasteModalPresented {
                    PasteModal(
                        pasteString: OnboardingPasteString.current,
                        pasteboard: SystemPasteboard(),
                        onAppear: { services.mcpActivity.arm() },
                        onCopy: { services.onboarding.send(.copyPasteString) },
                        onDismiss: {
                            services.mcpActivity.disarm()
                            services.onboarding.send(.closePasteModal)
                        }
                    )
                }
            }
            // Success toast — fires when `didCompleteSuccessfully` flips true
            .overlay(alignment: .bottom) {
                if showConnectedToast {
                    Text("Connected. Your routes are on the canvas.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.black.opacity(0.85))
                        )
                        .padding(.bottom, 72)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showConnectedToast)
            // Demo ribbon — top-centre, once per user on first demo render
            .overlay(alignment: .top) {
                DemoModeRibbon(isInDemoMode: services.demo.isInDemoMode)
                    .padding(.top, 12)
            }
            // NewServerToast was relocated into the top-right pill stack above so the
            // user reads server-detection events under the dev-server pill, not in an
            // unrelated corner.
            .animation(.easeInOut(duration: 0.25), value: services.newServerDetector.isVisible)
            .animation(.easeInOut(duration: 0.25), value: services.interactHintCoordinator.isVisible)
            .animation(.easeInOut(duration: 0.25), value: services.mcpState.isNudgeVisible)
    }

    private var canvasContent: some View {
        canvasVisualContent
            .task {
                services.interactionRouter.interactHintCoordinator = services.interactHintCoordinator
                // Wire palette state dependencies
                services.paletteState.routeDiscovery = services.routeDiscovery
                services.paletteState.document = services.document
                services.paletteState.onOpenDemoProject = { enterDemoMode() }
                // Wire workspace switcher dependencies
                services.switcherState.portScanner = services.portScanner
                services.switcherState.sessionPersistence = services.sessionPersistence
                services.switcherState.activePort = services.devServer.port
                // Wire new server detector — auto-connect when idle
                services.newServerDetector.onAutoConnect = { server in
                    switchToPort(server.port)
                }
                // MCP nudge — show after 3+ routes and 5 minutes of use, once only
                scheduleMCPNudge()
                // Onboarding v3 — MCP activity detector feeds the reducer.
                services.mcpActivity.onFirstListRoutes = {
                    AnalyticsService.shared.capture(.mcpFirstConnection, properties: nil)
                    services.onboarding.send(.mcpActivityDetected)
                }
                armOnboardingIfNeeded()
            }
            .onChange(of: services.devServer.serverURL) { _, newURL in
                // Sync primary DevServerManager → primary binding's origin so all frames
                // continue to load from the latest port. In C0 this is the only path that
                // mutates the primary binding's origin without going through registry.bind.
                guard let url = newURL else { return }
                let doc = services.document
                if let id = doc.primaryBindingId, let idx = doc.bindings.firstIndex(where: { $0.id == id }) {
                    doc.bindings[idx].origin = url
                    doc.bindings[idx].status = .connected
                    doc.bindings[idx].lastSeenAt = Date()
                }
                // Else: no primary binding yet — the projectDir onChange path below will
                // create one when projectDir resolves.
            }
            .onChange(of: services.devServer.projectDir) { oldDir, newDir in
                // CRITICAL (C0): this path runs only when the PRIMARY DevServerManager's
                // projectDir changes — i.e., a workspace-level switch. Adding a secondary
                // binding via the pill popover routes through DevServerRegistry.bind(port:),
                // which never touches DevServerManager.projectDir and therefore never triggers
                // this document-switch path. Don't add a non-primary side-effect here.

                // Stage 12: Save current state before switching projects
                if let _ = oldDir, !services.document.routes.isEmpty {
                    services.sessionPersistence.saveNow(
                        document: services.document,
                        port: services.devServer.port
                    )
                }

                guard let dir = newDir else { return }

                // Same-identity guard: when switching between two paths that resolve to the
                // same project (e.g. two conductor worktrees of the same repo on the same
                // port), keep the canvas as-is. Belt-and-braces — `load` would already
                // succeed via the shared cache key, but this protects against persistence
                // failures (corrupted file, disk error) wiping the user's frames.
                let identityChanged: Bool = {
                    guard let old = oldDir else { return true }
                    return services.sessionPersistence.cacheKey(projectDir: old)
                        != services.sessionPersistence.cacheKey(projectDir: dir)
                }()

                services.sessionPersistence.currentProjectDir = dir

                // Load the saved state up-front so we can restore bindings + primary id
                // BEFORE the route-restore loop runs (otherwise the back-fill points at
                // a stale binding). Falls through to the v1 path when no saved file
                // exists or when the file is pre-C0 (no `bindings` array).
                let savedState = identityChanged ? services.sessionPersistence.load(projectDir: dir) : nil

                let primaryOrigin = services.devServer.serverURL
                    ?? URL(string: "http://localhost:\(services.devServer.port)")!
                let primaryName: String = {
                    let pkg = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
                    if let data = try? Data(contentsOf: pkg),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = json["name"] as? String, !name.isEmpty { return name }
                    return URL(fileURLWithPath: dir).lastPathComponent
                }()

                // Restore bindings array from saved state when the v2 envelope is present.
                // Otherwise reset to just-the-primary so the C0 invariants hold.
                if identityChanged {
                    if let saved = savedState, let savedBindings = saved.bindings, !savedBindings.isEmpty {
                        services.document.bindings = savedBindings
                        services.document.primaryBindingId = saved.primaryBindingId
                            ?? savedBindings.first?.id
                    } else {
                        services.document.bindings = []
                        services.document.primaryBindingId = nil
                    }

                    // A1: restore canvases + snapshots. v3 files carry an explicit array;
                    // v1/v2 files migrate to a single Working Canvas with the flat fields
                    // as its active state.
                    if let saved = savedState, let savedCanvases = saved.canvases, !savedCanvases.isEmpty {
                        services.document.canvases = savedCanvases
                        // Stale activeCanvasId protection — fall back to Working Canvas.
                        let activeFromSave = saved.activeCanvasId.flatMap { id in
                            savedCanvases.first(where: { $0.id == id })?.id
                        }
                        services.document.activeCanvasId = activeFromSave
                            ?? savedCanvases.first(where: { $0.isDefault })?.id
                            ?? savedCanvases[0].id
                        if let snaps = saved.canvasSnapshots {
                            var rehydrated: [UUID: CanvasSnapshot] = [:]
                            for (key, value) in snaps {
                                if let id = UUID(uuidString: key) {
                                    rehydrated[id] = value
                                }
                            }
                            services.document.canvasSnapshots = rehydrated
                        } else {
                            services.document.canvasSnapshots = [:]
                        }
                    } else {
                        // v1/v2 file — reset to a single Working Canvas.
                        let working = Canvas.defaultWorkingCanvas()
                        services.document.canvases = [working]
                        services.document.activeCanvasId = working.id
                        services.document.canvasSnapshots = [:]
                    }
                }

                // Ensure a primary binding exists for the new identity. Bindings outlive
                // session switches when worktrees share identity; we mutate the existing
                // primary binding's origin/projectDir rather than minting a new id.
                if let primaryId = services.document.primaryBindingId,
                   let idx = services.document.bindings.firstIndex(where: { $0.id == primaryId }) {
                    services.document.bindings[idx].origin = primaryOrigin
                    services.document.bindings[idx].projectDir = dir
                    services.document.bindings[idx].displayName = primaryName
                    services.document.bindings[idx].status = .connected
                    services.document.bindings[idx].lastSeenAt = Date()
                } else {
                    let primary = ServerBinding(
                        id: UUID(),
                        origin: primaryOrigin,
                        displayName: primaryName,
                        projectDir: dir,
                        packageName: primaryName,
                        gitRemote: nil,
                        lastSeenAt: Date(),
                        status: .connected
                    )
                    services.document.bindings.append(primary)
                    services.document.primaryBindingId = primary.id
                }
                let primaryBindingId = services.document.primaryBindingId

                if identityChanged {
                    // Stage 12: Try to load saved state for new project
                    if let saved = savedState {
                        // Restore saved routes — back-fill serverBindingId to the primary
                        // binding so post-restore url(for:) calls resolve correctly. For v2
                        // sessions, the saved per-route serverBindingId wins (handled in
                        // SessionPersistence.load's mapping path).
                        services.document.routes = saved.routes.map { sr in
                            var route = RouteFrame(
                                id: UUID(),
                                path: sr.path,
                                serverBindingId: sr.serverBindingId ?? primaryBindingId,
                                x: sr.x,
                                y: sr.y,
                                width: sr.width,
                                height: sr.height,
                                zIndex: 0,
                                displayName: sr.displayName,
                                urlPath: sr.urlPath
                            )
                            route.captureDelay = sr.captureDelay
                            route.captureDelaySource = sr.captureDelaySource
                            route.isAnimatedDetected = sr.isAnimatedDetected
                            return route
                        }
                        // Restore saved markdown documents (preserve id — same file may appear twice)
                        services.document.documents = (saved.documents ?? []).map { sd in
                            MarkdownFrame(id: sd.id, filePath: sd.filePath,
                                          x: sd.x, y: sd.y, width: sd.width, height: sd.height,
                                          displayName: sd.displayName)
                        }
                        // Restore saved images
                        services.document.images = (saved.images ?? []).map { si in
                            ImageFrame(id: si.id, filePath: si.filePath,
                                       x: si.x, y: si.y, width: si.width, height: si.height,
                                       displayName: si.displayName)
                        }
                        // Restore saved sections (v4+); older sessions decode this as nil.
                        services.document.sections = (saved.sections ?? []).map { ss in
                            CanvasSection(id: ss.id, title: ss.title,
                                          x: ss.x, y: ss.y, width: ss.width, height: ss.height,
                                          routeIds: ss.routeIds, documentIds: ss.documentIds, imageIds: ss.imageIds)
                        }
                        // Restore active-canvas camera. Older files have no camera keys —
                        // leave the live camera untouched so callers (e.g. zoom-to-fit on
                        // first launch) still drive the viewport.
                        if let cx = saved.cameraX, let cy = saved.cameraY, let cz = saved.cameraZoom {
                            services.camera.origin = CGPoint(x: cx, y: cy)
                            services.camera.zoom = CGFloat(cz)
                            NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
                        }
                        // Stage 14b — restore active-canvas styling. Pre-14b sessions
                        // decode this as nil; fall through to canonicalDefault.
                        if let saved = saved.styling {
                            services.document.styling = saved
                        }
                        services.didAutoLoadRoot = true
                    } else {
                        // No saved state — clear old routes only when switching projects
                        if oldDir != nil {
                            services.document.routes = []
                            services.didAutoLoadRoot = false
                        }
                        if services.devServer.status == .running {
                            services.autoLoadRoot()
                        }
                    }
                }
                // Else: same project identity — keep routes/documents/images and
                // didAutoLoadRoot untouched. The next debounced save writes the unchanged
                // canvas under the same cache key, so disk state stays in sync.

                // Run route discovery — new routes appear in ⌘K palette
                let projectURL = URL(fileURLWithPath: dir)
                let _ = services.routeDiscovery.discoverRoutes(projectDir: projectURL)

                // Reset markdown file index — the palette's markdown picker will
                // re-walk lazily the next time it's opened.
                services.workspaceFileIndex.invalidate()

                // Drop heal hashes when the project identity actually changed; otherwise
                // basename collisions across projects could match a stale hash.
                if identityChanged {
                    services.markdownPathHealer.reset()
                }

                // Show route suggestion banner on first real connection
                checkRouteBanner()

                // Start file watcher for auto-refresh on source changes
                services.startFileWatcher(projectDir: dir)

                // Persist last active project for smart launch on next open
                services.saveLastActiveProject(dir)
            }
            .onChange(of: services.devServer.status) { oldStatus, newStatus in
                // When server becomes running and we haven't auto-loaded yet, do it
                if newStatus == .running && services.document.routes.isEmpty {
                    services.autoLoadRoot()
                }
                // Surface the dead-server state on every live frame so the user sees
                // an overlay instead of a blank white box. Reload + clear on recovery.
                if oldStatus == .running && newStatus == .disconnected
                    && !services.document.routes.isEmpty {
                    services.markLiveFramesServerUnreachable()
                } else if oldStatus == .disconnected && newStatus == .running
                    && !services.document.routes.isEmpty {
                    services.reloadAllLiveFrames()
                }
                // Keep switcher's active port in sync
                services.switcherState.activePort = services.devServer.port
                // Onboarding v3 — report running so the reducer can hide the demo panel /
                // welcome box. Modal presentation is orthogonal and stays on its own path.
                services.onboarding.send(
                    .devServerStatusChanged(
                        running: newStatus == .running,
                        port: services.devServer.port
                    )
                )
                // Re-arm the welcome box on genuine Peter-path transitions (not a demo
                // hand-off, which sets skipWelcomeOnNextRunningTransition).
                if newStatus == .running {
                    armOnboardingIfNeeded()
                }
            }
            .onChange(of: accountIntegrationsEnabled) { _, enabled in
                if enabled {
                    services.claudeAccounts.startAll()
                    services.openAIUsage.start()
                } else {
                    services.claudeAccounts.stopAll()
                    services.openAIUsage.stop()
                }
            }
            .onChange(of: services.demo.isInDemoMode) { _, nowInDemo in
                // smartLaunch() flips this flag asynchronously — the initial arm attempt in
                // `.task` runs too early to see it. Re-arm when demo mode actually activates.
                if nowInDemo {
                    armOnboardingIfNeeded()
                }
            }
            .onChange(of: services.document.routes.count) { oldValue, newValue in
                // Onboarding v3 — signal second success gate when routes first appear.
                if oldValue == 0 && newValue > 0 {
                    services.onboarding.send(.routesBecameLive)
                }
            }
            .onChange(of: services.onboarding.didCompleteSuccessfully) { _, completed in
                guard completed else { return }
                showConnectedToast = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    showConnectedToast = false
                }
            }
            .onChange(of: services.portScanner.detectedServers) { _, newServers in
                if services.demo.isInDemoMode {
                    // Feed detected servers to pill State 2 (not to NewServerDetector)
                    services.demo.demoDetectedServers = newServers
                    if !newServers.isEmpty {
                        print("[Demo] Servers detected during demo: \(newServers.map { "\($0.projectName):\($0.port)" })")
                    }

                    // Onboarding v3 — after paste-modal opened from the demo panel, the
                    // user's agent boots their dev server; auto-connect on first sight.
                    if services.onboarding.pendingDemoAutoConnect, let first = newServers.first {
                        services.skipWelcomeOnNextRunningTransition = true
                        services.onboarding.send(.clearPendingDemoAutoConnect)
                        exitDemoMode(connectToPort: first.port)
                    }
                } else {
                    // Normal: feed to toast/auto-connect detector. activePorts is the union
                    // of the primary controller's port + every bound binding's port — any
                    // of those should be filtered as "already known" by the detector.
                    let isDisconnected = services.devServer.status == .disconnected
                    var activePorts: Set<Int> = [services.devServer.port]
                    for binding in services.document.bindings {
                        if let p = binding.port { activePorts.insert(p) }
                    }
                    services.newServerDetector.processNewScan(
                        servers: newServers,
                        activePorts: activePorts,
                        isDisconnected: isDisconnected
                    )

                    // Phase D: check for "server moved port" matches against stale bindings.
                    // Only strong/medium matches surface as a toast; weak matches stay in
                    // the popover (worktree case avoids false-positive prompts).
                    if pendingRebindCandidate == nil {
                        let boundPorts: Set<Int> = Set(services.document.bindings.compactMap { $0.port })
                        let matches = PortRebindMatcher.scan(
                            bindings: services.document.bindings,
                            detected: newServers,
                            boundPorts: boundPorts
                        )
                        let strongOrMedium = matches.first { m in
                            (m.confidence == .strong || m.confidence == .medium)
                            && !dismissedRebindBindingIds.contains(m.binding.id)
                        }
                        if let m = strongOrMedium {
                            let count = services.document.routes.filter { $0.serverBindingId == m.binding.id }.count
                            pendingRebindCandidate = PortRebindCandidate(
                                id: m.binding.id,
                                displayName: m.binding.displayName,
                                oldPort: m.binding.port,
                                newPort: m.newServer.port,
                                affectedRouteCount: count
                            )
                        }
                    }
                }
            }
    }

    var body: some Scene {
        WindowGroup(id: "canvas") {
            canvasContent
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Design Canvas") {
                    let credits = NSMutableAttributedString()

                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.alignment = .center
                    paragraphStyle.paragraphSpacing = 4

                    let mutedAttrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor(red: 0x88/255.0, green: 0x88/255.0, blue: 0x88/255.0, alpha: 1.0),
                        .font: NSFont.systemFont(ofSize: 12),
                        .paragraphStyle: paragraphStyle
                    ]
                    let linkAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12),
                        .paragraphStyle: paragraphStyle
                    ]

                    credits.append(NSAttributedString(string: "Built by Charlie Ellington\n\n", attributes: mutedAttrs))

                    let emailLink = NSMutableAttributedString(string: "charlie@ellington.design", attributes: linkAttrs)
                    emailLink.addAttribute(.link, value: URL(string: "mailto:charlie@ellington.design")!, range: NSRange(location: 0, length: emailLink.length))
                    credits.append(emailLink)

                    credits.append(NSAttributedString(string: "  ·  ", attributes: mutedAttrs))

                    let telegramLink = NSMutableAttributedString(string: "Telegram", attributes: linkAttrs)
                    telegramLink.addAttribute(.link, value: URL(string: "https://t.me/charlieellington")!, range: NSRange(location: 0, length: telegramLink.length))
                    credits.append(telegramLink)

                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: credits
                    ])
                }

                Button("Check for Updates…") {
                    updaterManager.checkForUpdates()
                }
                .disabled(!updaterManager.canCheckForUpdates)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    services.document.undoManager.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!services.document.undoManager.canUndo)

                Button("Redo") {
                    services.document.undoManager.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!services.document.undoManager.canRedo)
            }

            CommandMenu("Project") {
                Button("Switch Workspace…") {
                    services.switcherState.toggle()
                }

                Button("Open Project…") {
                    openProjectPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Discover Routes") {
                    discoverRoutes()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(services.devServer.projectDir == nil)

                Divider()

                Button("Check for Server") {
                    services.devServer.connect(port: services.devServer.port)
                }
                .disabled(services.devServer.status == .running)

                Button("Stop Server") {
                    services.devServer.stopServer()
                }
                .disabled(!services.devServer.didSpawn)
            }

            CommandMenu("Canvas") {
                Button("Switch Canvas…") {
                    isCanvasSwitcherPresented.toggle()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Canvas") {
                    createNewCanvas()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Duplicate to New Canvas") {
                    duplicateSelectionToNewCanvas()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Add Routes…") {
                    services.paletteState.open()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Connect Your Project…") {
                    services.onboarding.send(
                        .openPasteModal(
                            source: .keyboardShortcut,
                            hasLiveRoutes: services.document.routes.count > 0
                        )
                    )
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("MCP…") {
                    services.mcpState.isSheetOpen.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Toggle("Enable Account Usage Integrations", isOn: $accountIntegrationsEnabled)
                Divider()
                Button("Zoom In") {
                    services.camera.zoom = services.camera.clampedZoom(services.camera.zoom * 1.5)
                    NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    services.camera.zoom = services.camera.clampedZoom(services.camera.zoom / 1.5)
                    NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    services.camera.zoom = 1.0
                    NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button(services.claudeUsage.permanentlyHidden ? "Show Claude Usage" : "Hide Claude Usage") {
                    let willShow = services.claudeUsage.permanentlyHidden
                    services.claudeUsage.permanentlyHidden.toggle()
                    services.claudeUsage.sessionHidden = false
                    if willShow {
                        services.claudeUsage.resetSelectedOrg()
                        services.claudeUsage.refreshNow()
                    }
                }
            }

            #if DEBUG
            // Stage 14b dev preset cycler. Apply preset 1-4 from the bundled
            // StylingPresets.json so Charlie can walk the placeholder presets
            // during the Stage 14c gate without depending on Stage 16a's action
            // cluster. Release builds omit this menu via #if DEBUG.
            CommandMenu("Dev") {
                Button("Apply Preset 1") { applyDevPreset(index: 0) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Apply Preset 2") { applyDevPreset(index: 1) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Apply Preset 3") { applyDevPreset(index: 2) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Apply Preset 4") { applyDevPreset(index: 3) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
            }
            #endif

            // Stage 16a — Share Mode commands.
            CommandMenu("Share") {
                Button("Enter Share Mode") {
                    services.shareMode.enter(trigger: .keyboardShortcut)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Create Link") {
                    Task { await services.shareMode.createLink() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(services.shareMode.state != .active)

                Button("Exit Share Mode") {
                    services.shareMode.exit(reason: .escape)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(services.shareMode.state != .active)

                Button("Restore all frames") {
                    services.shareMode.restoreAllFrames()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(services.shareMode.state != .active)

                Button("Copy last share link") {
                    if let url = services.shareMode.lastCreatedShareURL {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    showKeyboardShortcutsWindow()
                }

                Button("Open Log File") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: FileLogger.shared.path))
                }

                Divider()

                Button("Design Canvas Website") {
                    if let url = URL(string: "https://designcanvas.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Menu bar Claude usage pills — account 1 always; account 2 once added.
        // Each is a separate menu bar item; content/label are extracted to computed
        // views so this Scene body stays within the type-checker's budget.
        MenuBarExtra(isInserted: .constant(accountIntegrationsEnabled && !services.claudeAccounts.primaryAccount.isHidden)) {
            primaryMenuBarContent
        } label: {
            primaryMenuBarLabel
        }
        .menuBarExtraStyle(.window)

        // Account 2 — declared unconditionally and shown only when a second account
        // exists and isn't hidden. (An `if let` here makes the Scene body untypeable.)
        MenuBarExtra(
            isInserted: .constant(
                accountIntegrationsEnabled && services.claudeAccounts.hasSecondAccount
                    && !services.claudeAccounts.secondMenuBarAccount.isHidden
            )
        ) {
            secondMenuBarContent(services.claudeAccounts.secondMenuBarAccount)
        } label: {
            secondMenuBarLabel(services.claudeAccounts.secondMenuBarAccount)
        }
        .menuBarExtraStyle(.window)

        // Read-only OpenAI/Codex subscription usage. Declared unconditionally so
        // signed-out and unavailable states remain reachable from the menu bar.
        MenuBarExtra(isInserted: .constant(accountIntegrationsEnabled)) {
            openAIUsageMenuBarContent
        } label: {
            openAIUsageMenuBarLabel
        }
        .menuBarExtraStyle(.window)

        // Terminal-command palette — always-available menu bar item; click a
        // command to copy it, then paste into the terminal.
        MenuBarExtra {
            terminalMenuBarContent
        } label: {
            terminalMenuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
    /// Stage 14b dev preset cycler. Applies the bundled preset at `index` to the
    /// active canvas's styling and triggers a re-render via the document's
    /// @Observable change. ~30 lines (Stage 14b spec).
    private func applyDevPreset(index: Int) {
        guard let preset = PresetManager.shared.preset(atIndex: index) else {
            print("[Dev] No preset at index \(index)")
            return
        }
        services.document.styling = preset.config
        print("[Dev] Applied preset \(preset.id) (\(preset.displayName))")
    }
    #endif

    private func showKeyboardShortcutsWindow() {
        let shortcuts = """
        ⌘T          Switch Canvas
        ⌘⇧N         New Canvas
        ⌘⇧D         Duplicate to New Canvas
        ⌘K          Add Routes
        ⌘⇧K         Connect Your Project
        ⌘⇧O         Open Project
        ⌘⇧R         Discover Routes
        ⌘⇧M         MCP Setup
        ⌘+          Zoom In
        ⌘-          Zoom Out
        ⌘0          Actual Size
        ⌘Z          Undo
        ⌘⇧Z         Redo
        Space+Drag  Pan Canvas
        Double-click Enter Focus Mode
        Escape      Exit Focus Mode
        Delete      Remove Frame
        """
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = shortcuts
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Route Suggestion Banner

    private var addableRouteCount: Int {
        let onCanvas = Set(services.document.routes.map(\.path))
        return services.routeDiscovery.lastDiscovered
            .filter { !onCanvas.contains($0.label) }
            .filter { !$0.label.hasPrefix("/api") }
            .filter { !$0.label.contains("[") }
            .count
    }

    private func checkRouteBanner() {
        guard !services.demo.isInDemoMode else { return }
        guard !UserDefaults.standard.bool(forKey: "hasSeenRoutePrompt") else { return }
        guard addableRouteCount > 0 else { return }
        showRouteBanner = true
    }

    private func addSuggestedRoutes() {
        let onCanvas = Set(services.document.routes.map(\.path))
        let addable = services.routeDiscovery.lastDiscovered
            .filter { !onCanvas.contains($0.label) }
            .filter { !$0.label.hasPrefix("/api") }
            .filter { !$0.label.contains("[") }
        services.document.mergeDiscoveredRoutes(
            services.document.routes.map { DiscoveredRoute(label: $0.path, urlPath: $0.urlPath ?? $0.path) }
            + addable
        )
        dismissRouteBanner()
    }

    private func dismissRouteBanner() {
        showRouteBanner = false
        UserDefaults.standard.set(true, forKey: "hasSeenRoutePrompt")
    }

    // MARK: - Claude accounts

    /// One pill per tracked account, rendered in the top-right pill row. Extracted
    /// from the Scene body so the type-checker handles it independently.
    @ViewBuilder
    private var claudeUsagePills: some View {
        ForEach(services.claudeAccounts.accounts) { account in
            if !account.isHidden {
                ClaudeUsagePill(
                    service: account,
                    showAccountLabel: services.claudeAccounts.accounts.count > 1,
                    onLoginTap: { loginSheetAccount = account },
                    onSwitchAccount: {
                        // Wipe cookies + flip to .unauthenticated, then open the
                        // login sheet cold so claude.ai shows the sign-in form
                        // (not an auto-redirect into the previous session).
                        account.signOut()
                        loginSheetAccount = account
                    },
                    onAddAccount: addAccountAction(for: account),
                    onRemoveAccount: removeAccountAction(for: account)
                )
            }
        }
    }

    /// "Add another account…" action for an account's popover — offered only on
    /// account 1, and only while a second slot is free. Creates the second
    /// account (its own isolated profile) and routes straight to its login sheet.
    private func addAccountAction(for account: ClaudeUsageService) -> (() -> Void)? {
        guard account === services.claudeAccounts.primaryAccount,
              services.claudeAccounts.canAddAccount else { return nil }
        return {
            if let new = services.claudeAccounts.addSecondAccount() {
                loginSheetAccount = new
            }
        }
    }

    /// "Remove this account" action — offered only on the second account's popover.
    private func removeAccountAction(for account: ClaudeUsageService) -> (() -> Void)? {
        guard account === services.claudeAccounts.secondAccount else { return nil }
        return { services.claudeAccounts.removeSecondAccount() }
    }

    // Menu bar content/label extracted so the MenuBarExtra shells in the Scene body
    // stay trivial (a property reference), keeping the whole body type-checkable.

    @ViewBuilder
    private var primaryMenuBarContent: some View {
        ClaudeMenuBarPopover(
            service: services.claudeAccounts.primaryAccount,
            onRequestLogin: { loginSheetAccount = services.claudeAccounts.primaryAccount },
            onAddAccount: addAccountAction(for: services.claudeAccounts.primaryAccount),
            onRemoveAccount: nil
        )
    }

    @ViewBuilder
    private var primaryMenuBarLabel: some View {
        ClaudeMenuBarLabel(
            service: services.claudeAccounts.primaryAccount,
            showAccountLabel: services.claudeAccounts.accounts.count > 1
        )
    }

    @ViewBuilder
    private func secondMenuBarContent(_ second: ClaudeUsageService) -> some View {
        ClaudeMenuBarPopover(
            service: second,
            onRequestLogin: { loginSheetAccount = second },
            onAddAccount: nil,
            onRemoveAccount: { services.claudeAccounts.removeSecondAccount() }
        )
    }

    @ViewBuilder
    private func secondMenuBarLabel(_ second: ClaudeUsageService) -> some View {
        ClaudeMenuBarLabel(service: second, showAccountLabel: true)
    }

    @ViewBuilder
    private var openAIUsageMenuBarContent: some View {
        OpenAIUsagePopover(service: services.openAIUsage)
    }

    @ViewBuilder
    private var openAIUsageMenuBarLabel: some View {
        OpenAIMenuBarLabel(service: services.openAIUsage)
    }

    @ViewBuilder
    private var terminalMenuBarContent: some View {
        TerminalCommandsPopover(store: services.terminalCommands, onDismiss: {})
    }

    @ViewBuilder
    private var terminalMenuBarLabel: some View {
        Image(systemName: "terminal")
    }

    // MARK: - Demo Mode

    /// Enter demo mode — used by ⌘K "Open Demo Project".
    private func enterDemoMode() {
        // Save current real project state before entering demo
        if !services.demo.isInDemoMode, services.devServer.projectDir != nil {
            services.sessionPersistence.saveNow(
                document: services.document,
                port: services.devServer.port
            )
        }

        services.stopFileWatcher()
        services.demo.isInDemoMode = true
        services.demo.demoDetectedServers = []
        services.document.routes = []
        services.document.screenshots = [:]
        services.document.loadDemoRoutes()
        NotificationCenter.default.post(name: .resetZoomToFit, object: nil)
        services.routeDiscovery.clearDiscovered()
        showRouteBanner = false
    }

    /// Exit demo mode and connect to a real server.
    private func exitDemoMode(connectToPort port: Int) {
        // Remember current projectDir — if it doesn't change after connect,
        // onChange won't fire and we need to restore routes manually.
        let previousDir = services.devServer.projectDir

        withAnimation(.easeInOut(duration: 0.3)) {
            services.demo.isInDemoMode = false
            services.demo.demoDetectedServers = []
            services.document.routes = []
            services.document.screenshots = [:]
        }
        services.document.undoManager.removeAllActions()
        services.didAutoLoadRoot = false
        NotificationCenter.default.post(name: .resetZoomToFit, object: nil)
        switchToPort(port)

        // If projectDir didn't change (re-entering same project after demo),
        // onChange won't fire — restore saved routes and restart file watcher manually.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if services.devServer.projectDir == previousDir, let dir = previousDir {
                if let saved = services.sessionPersistence.load(projectDir: dir) {
                    let primaryBindingId = services.document.primaryBindingId
                    services.document.routes = saved.routes.map { sr in
                        var route = RouteFrame(
                            id: UUID(),
                            path: sr.path,
                            serverBindingId: sr.serverBindingId ?? primaryBindingId,
                            x: sr.x,
                            y: sr.y,
                            width: sr.width,
                            height: sr.height,
                            zIndex: 0,
                            displayName: sr.displayName,
                            urlPath: sr.urlPath
                        )
                        route.captureDelay = sr.captureDelay
                        route.captureDelaySource = sr.captureDelaySource
                        route.isAnimatedDetected = sr.isAnimatedDetected
                        return route
                    }
                    services.document.documents = (saved.documents ?? []).map { sd in
                        MarkdownFrame(id: sd.id, filePath: sd.filePath,
                                      x: sd.x, y: sd.y, width: sd.width, height: sd.height,
                                      displayName: sd.displayName)
                    }
                    services.document.images = (saved.images ?? []).map { si in
                        ImageFrame(id: si.id, filePath: si.filePath,
                                   x: si.x, y: si.y, width: si.width, height: si.height,
                                   displayName: si.displayName)
                    }
                    services.document.sections = (saved.sections ?? []).map { ss in
                        CanvasSection(id: ss.id, title: ss.title,
                                      x: ss.x, y: ss.y, width: ss.width, height: ss.height,
                                      routeIds: ss.routeIds, documentIds: ss.documentIds, imageIds: ss.imageIds)
                    }
                    if let saved = saved.styling {
                        services.document.styling = saved
                    }
                    services.didAutoLoadRoot = true
                } else if services.devServer.status == .running {
                    services.autoLoadRoot()
                }
                let projectURL = URL(fileURLWithPath: dir)
                let _ = services.routeDiscovery.discoverRoutes(projectDir: projectURL)
                services.startFileWatcher(projectDir: dir)
            }
        }

        scheduleMCPNudge()
    }

    // MARK: - Onboarding wiring (v3)

    private var showsBottomCenterOnboarding: Bool {
        switch services.onboarding.basePhase {
        case .demoPanel, .devServerWelcome:
            return true
        default:
            return false
        }
    }

    private func armOnboardingIfNeeded() {
        if services.isShareLinkSession {
            services.onboarding.send(.markHidden)
            return
        }

        let welcomeShown = UserDefaults.standard.bool(forKey: "onboardingWelcomeBoxShown")

        if services.devServer.status == .running {
            if services.skipWelcomeOnNextRunningTransition {
                services.skipWelcomeOnNextRunningTransition = false
                services.onboarding.send(.markHidden)
            } else {
                services.onboarding.send(welcomeShown ? .markHidden : .showDevServerWelcome)
            }
            return
        }

        if services.demo.isInDemoMode {
            services.onboarding.send(.showDemoPanel)
            return
        }

        services.onboarding.send(.markHidden)
    }

    private func switchToPort(_ port: Int) {
        // Stop spawned server before switching ports to avoid orphans
        if services.devServer.didSpawn {
            services.devServer.stopServer()
        }
        CrashReporter.shared.breadcrumb(category: "workspace", action: "switch", message: "port:\(port)")
        AnalyticsService.shared.capture(.workspaceSwitched)
        services.devServer.connect(port: port)
    }

    // MARK: - Canvas operations (A1)

    /// Switch to a different canvas. Snapshots the current canvas's flat slots into
    /// `canvasSnapshots`, restores the target canvas's snapshot into the flat slots.
    /// Active canvas's contents are never present in `canvasSnapshots`.
    private func switchCanvas(to canvasId: UUID) {
        guard canvasId != services.document.activeCanvasId else { return }
        guard services.document.canvases.contains(where: { $0.id == canvasId }) else { return }

        // Snapshot the current canvas (camera optional — pan/zoom carries across switches).
        let outgoingId = services.document.activeCanvasId
        let outgoingSnap = services.document.captureActiveSnapshot(camera: services.camera)
        services.document.canvasSnapshots[outgoingId] = outgoingSnap

        // Restore the target canvas's snapshot (or empty state if first-time switch).
        if let incoming = services.document.canvasSnapshots.removeValue(forKey: canvasId) {
            services.document.restoreSnapshot(incoming)
            if let cx = incoming.cameraX, let cy = incoming.cameraY, let cz = incoming.cameraZoom {
                services.camera.origin = CGPoint(x: CGFloat(cx), y: CGFloat(cy))
                services.camera.zoom = CGFloat(cz)
                NotificationCenter.default.post(name: .cameraNeedsSync, object: nil)
            }
        } else {
            // Fresh canvas — empty content, no snapshot yet.
            services.document.routes = []
            services.document.documents = []
            services.document.images = []
            services.document.screenshots = [:]
            services.document.bindings = []
            services.document.primaryBindingId = nil
            services.document.undoManager.removeAllActions()
        }

        services.document.activeCanvasId = canvasId
        services.sessionPersistence.scheduleSave(
            document: services.document,
            port: services.devServer.port
        )
        AnalyticsService.shared.capture(.workspaceSwitched)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "switch", message: canvasId.uuidString)
    }

    /// Create a new empty canvas + switch to it.
    private func createNewCanvas() {
        let canvas = Canvas(name: nextUntitledName(), createdAt: Date(), updatedAt: Date())
        services.document.canvases.append(canvas)
        switchCanvas(to: canvas.id)
    }

    /// Duplicate a canvas's contents into a fresh canvas (and switch to it). Snapshots
    /// the source canvas first (if it's the active one) so we always have a clean copy.
    private func duplicateCanvas(_ source: Canvas) {
        let sourceSnap: CanvasSnapshot
        if source.id == services.document.activeCanvasId {
            sourceSnap = services.document.captureActiveSnapshot(camera: services.camera)
        } else if let snap = services.document.canvasSnapshots[source.id] {
            sourceSnap = snap
        } else {
            sourceSnap = CanvasSnapshot(routes: [], documents: [], images: [], bindings: [], primaryBindingId: nil, cameraX: nil, cameraY: nil, cameraZoom: nil)
        }
        // New canvas inherits the source's content but mints fresh route IDs (so
        // screenshots aren't shared and ghost-pin coordinates can diverge later).
        let dup = Canvas(name: "\(source.name) copy", createdAt: Date(), updatedAt: Date())
        services.document.canvases.append(dup)
        // Stash the source's snapshot under the new id so switchCanvas restores it.
        services.document.canvasSnapshots[dup.id] = sourceSnap
        switchCanvas(to: dup.id)
    }

    /// Rename a canvas via NSAlert prompt.
    private func renameCanvas(_ canvas: Canvas) {
        guard !canvas.isDefault else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Canvas"
        alert.informativeText = "Enter a new name for this canvas."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = canvas.name
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if let idx = services.document.canvases.firstIndex(where: { $0.id == canvas.id }) {
                services.document.canvases[idx].name = trimmed
                services.document.canvases[idx].updatedAt = Date()
                services.sessionPersistence.scheduleSave(
                    document: services.document, port: services.devServer.port
                )
            }
        }
    }

    /// Delete a non-default canvas. Switches to Working Canvas if the deleted one was active.
    private func deleteCanvas(_ canvas: Canvas) {
        guard !canvas.isDefault else { return }
        let isActive = canvas.id == services.document.activeCanvasId
        if isActive {
            // Switch to Working Canvas first so the flat slots aren't tied to the deleted id.
            if let working = services.document.canvases.first(where: { $0.isDefault }) {
                switchCanvas(to: working.id)
            }
        }
        services.document.canvases.removeAll { $0.id == canvas.id }
        services.document.canvasSnapshots.removeValue(forKey: canvas.id)
        services.sessionPersistence.scheduleSave(
            document: services.document, port: services.devServer.port
        )
    }

    /// "Duplicate selection to new canvas" — used by ⌘⇧D. Captures selected frames
    /// (or all frames when nothing's selected) onto a brand-new canvas at the same
    /// positions, then switches to it. Each frame's serverBindingId is preserved.
    private func duplicateSelectionToNewCanvas() {
        let selectedIds = services.interactionRouter.selectedFrameIds
        let scope: (RouteFrame) -> Bool = selectedIds.isEmpty
            ? { _ in true }
            : { selectedIds.contains($0.id) }
        let scopeDoc: (MarkdownFrame) -> Bool = selectedIds.isEmpty
            ? { _ in true }
            : { selectedIds.contains($0.id) }
        let scopeImg: (ImageFrame) -> Bool = selectedIds.isEmpty
            ? { _ in true }
            : { selectedIds.contains($0.id) }

        let pickedRoutes = services.document.routes.filter { !$0.isRemoved && scope($0) }
        let pickedDocs = services.document.documents.filter(scopeDoc)
        let pickedImgs = services.document.images.filter(scopeImg)
        guard !(pickedRoutes.isEmpty && pickedDocs.isEmpty && pickedImgs.isEmpty) else {
            NSSound.beep()
            return
        }

        let snapshot = CanvasSnapshot(
            routes: pickedRoutes.map { r in
                SavedRoute(
                    path: r.path,
                    urlPath: r.urlPath,
                    displayName: r.displayName,
                    x: r.x, y: r.y, width: r.width, height: r.height,
                    serverBindingId: r.serverBindingId
                )
            },
            documents: pickedDocs.map {
                SavedMarkdownFrame(id: $0.id, filePath: $0.filePath, displayName: $0.displayName,
                                   x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            images: pickedImgs.map {
                SavedImageFrame(id: $0.id, filePath: $0.filePath, displayName: $0.displayName,
                                x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            bindings: services.document.bindings,
            primaryBindingId: services.document.primaryBindingId,
            cameraX: Double(services.camera.origin.x),
            cameraY: Double(services.camera.origin.y),
            cameraZoom: Double(services.camera.zoom)
        )
        let name = nextUntitledName()
        let canvas = Canvas(name: name, createdAt: Date(), updatedAt: Date())
        services.document.canvases.append(canvas)
        services.document.canvasSnapshots[canvas.id] = snapshot
        switchCanvas(to: canvas.id)
    }

    private func nextUntitledName() -> String {
        let existing = Set(services.document.canvases.map(\.name))
        var i = 1
        while existing.contains("Canvas \(i)") { i += 1 }
        return "Canvas \(i)"
    }

    /// Phase D — apply a rebind by mutating the existing binding's origin/port in place.
    /// Routes keep their serverBindingId, so they pick up the new origin on the next
    /// url(for:) call. The TileLifecycle reload cycle drives the actual WKWebView reload.
    private func applyRebind(_ candidate: PortRebindCandidate) {
        guard let idx = services.document.bindings.firstIndex(where: { $0.id == candidate.id }) else {
            pendingRebindCandidate = nil
            return
        }
        let newOrigin = URL(string: "http://localhost:\(candidate.newPort)")!
        services.document.bindings[idx].origin = newOrigin
        services.document.bindings[idx].status = .connected
        services.document.bindings[idx].lastSeenAt = Date()
        CrashReporter.shared.breadcrumb(
            category: "workspace", action: "rebind",
            message: "\(candidate.displayName) → :\(candidate.newPort)"
        )
        // If this binding is also the primary, route the primary controller at the new
        // port too (which will trigger the projectDir-onChange session-load path).
        if services.document.primaryBindingId == candidate.id {
            switchToPort(candidate.newPort)
        } else {
            // Reload routes attached to this binding so live WebViews pick up the new origin.
            services.reloadFramesForBinding(candidate.id)
        }
        pendingRebindCandidate = nil
    }

    private func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        services.openProject(directory: url.path)
    }

    private func discoverRoutes() {
        guard let dir = services.devServer.projectDir else { return }
        let projectURL = URL(fileURLWithPath: dir)
        let discovered = services.routeDiscovery.discoverRoutes(projectDir: projectURL)
        if !discovered.isEmpty {
            services.document.mergeDiscoveredRoutes(discovered)
        }
    }

    /// Show MCP nudge toast after 5 minutes if user has 3+ routes and no MCP connection.
    private func scheduleMCPNudge() {
        guard !services.mcpState.hasShownNudge else { return }
        guard !services.demo.isInDemoMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [services] in
            guard !services.mcpState.hasShownNudge,
                  !services.mcpState.isConnected,
                  !services.demo.isInDemoMode,
                  services.document.routes.count >= 3 else { return }
            services.mcpState.isNudgeVisible = true
            services.mcpState.hasShownNudge = true
        }
    }
}

// MARK: - AppDelegate — starts HTTP server and probes dev server on launch

class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app is launched as a test host by XCTest.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip heavy startup when running as XCTest host
        guard !Self.isRunningTests else { return }

        // Force dark mode — the app is designed exclusively for dark appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Single-instance enforcement — bring existing instance to front
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != myPID }

        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        // Pause background polling when app is hidden to save battery
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            AppServices.shared.portScanner.stopPeriodicScan()
            AppServices.shared.fileWatcher?.stop()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            guard ProcessInfo.processInfo.environment["DESIGN_CANVAS_DEMO"] != "1" else { return }
            AppServices.shared.portScanner.startPeriodicScan()
            if let dir = AppServices.shared.devServer.projectDir {
                AppServices.shared.startFileWatcher(projectDir: dir)
            }
        }

        CrashReporter.shared.start()
        AnalyticsService.shared.start()
        FileLogger.shared.log("App launched — log file: \(FileLogger.shared.path)", tag: "App")

        // Flush analytics when app loses focus or terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in AnalyticsService.shared.flush() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in AnalyticsService.shared.flush() }

        Task { @MainActor in
            AppServices.shared.startHTTPServer()
            AppServices.shared.mcpState.checkInstalledConfigs()
            // Smart launch — scan all ports and connect to the best one
            AppServices.shared.smartLaunch()
            // Start Claude usage pollers — one per tracked account. Each is a
            // no-op when signed out, and reads its cookie from its own
            // WKWebsiteDataStore so it works the moment that account's login completes.
            AppServices.shared.claudeAccounts.startAll()
            // Start the read-only local Codex App Server bridge. It keeps polling
            // while the canvas window is closed, just like the Claude items.
            AppServices.shared.openAIUsage.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stage 12: Save session state immediately before exit
        AppServices.shared.sessionPersistence.saveNow(
            document: AppServices.shared.document,
            port: AppServices.shared.devServer.port
        )
        // Stop file watcher and port scanner before termination
        AppServices.shared.fileWatcher?.stop()
        AppServices.shared.portScanner.stopPeriodicScan()
        AppServices.shared.claudeAccounts.stopAll()
        AppServices.shared.openAIUsage.stop()
        // Kill any spawned dev server so Node.js doesn't survive as an orphan
        AppServices.shared.devServer.stopServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // false so the menu bar usage pill keeps polling after the canvas
        // window is closed. ⌘Q still terminates as normal.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock-icon click (or relaunch via single-instance handoff) reopens
        // the canvas WindowGroup. SwiftUI handles the actual restore when we
        // return true and there are no visible windows.
        true
    }
}

extension Notification.Name {
    static let cameraNeedsSync = Notification.Name("cameraNeedsSync")
    static let resetZoomToFit = Notification.Name("resetZoomToFit")
}
