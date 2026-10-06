// Holds the list of route frames and their cached screenshots. Source of truth for canvas content.

import Foundation
import Observation

@Observable
class DocumentModel {
    var routes: [RouteFrame] = []
    var documents: [MarkdownFrame] = []
    var images: [ImageFrame] = []
    var sections: [CanvasSection] = []
    var screenshots: [UUID: URL] = [:]

    /// Stage 14b — styling applied to the canvas matte (background) and per-frame
    /// chrome (corners + shadow + padding tint). Flat on DocumentModel for now;
    /// per-canvas via CanvasSnapshot.styling so switching canvases round-trips.
    /// At first-share time this becomes the create-time default; after creation
    /// the WEB owns styling via PATCH /styling (cross-stage §3).
    var styling: StylingConfig = .canonicalDefault

    /// Per-canvas dev-server bindings. C0: lives on DocumentModel because there is
    /// only one canvas. A1 will hoist this onto Canvas.
    var bindings: [ServerBinding] = []

    /// Which binding is the "primary" — the one whose project identity backs the
    /// document's session (driven by the existing single-server DevServerManager).
    /// Nil before first connect; remains nil while in demo mode.
    var primaryBindingId: UUID?

    // MARK: - Canvases (A1)

    /// The canvases tracked in this document. Always contains exactly one Working
    /// Canvas (`isDefault == true`). User-created canvases are appended after it.
    var canvases: [Canvas]

    /// Active canvas id. Always points at one of `canvases`. The flat slots above
    /// (routes/documents/images/screenshots/bindings/primaryBindingId) hold THIS
    /// canvas's contents; inactive canvases' contents live in `canvasSnapshots`.
    var activeCanvasId: UUID

    /// Inactive canvases' contents, keyed by canvas id. The active canvas's id is
    /// NEVER present here — its contents live in the flat slots.
    var canvasSnapshots: [UUID: CanvasSnapshot] = [:]

    init() {
        let working = Canvas.defaultWorkingCanvas()
        self.canvases = [working]
        self.activeCanvasId = working.id
    }

    var activeCanvas: Canvas {
        if let match = canvases.first(where: { $0.id == activeCanvasId }) { return match }
        // Defensive: active id pointing at a deleted canvas. Reset to Working Canvas.
        if let working = canvases.first(where: { $0.isDefault }) {
            activeCanvasId = working.id
            return working
        }
        // Even more defensive: no Working Canvas at all. Re-create.
        let recovered = Canvas.defaultWorkingCanvas()
        canvases.insert(recovered, at: 0)
        activeCanvasId = recovered.id
        return recovered
    }

    /// Snapshot the current flat slots into a `CanvasSnapshot`. Called before a
    /// canvas switch so we can restore on switching back.
    func captureActiveSnapshot(camera: CanvasCamera? = nil) -> CanvasSnapshot {
        let savedRoutes = routes.filter { !$0.isRemoved }.map { r in
            SavedRoute(
                path: r.path,
                urlPath: r.urlPath,
                displayName: r.displayName,
                x: r.x, y: r.y, width: r.width, height: r.height,
                serverBindingId: r.serverBindingId,
                captureDelay: r.captureDelay,
                captureDelaySource: r.captureDelaySource,
                isAnimatedDetected: r.isAnimatedDetected
            )
        }
        let savedDocs = documents.map { d in
            SavedMarkdownFrame(
                id: d.id, filePath: d.filePath, displayName: d.displayName,
                x: d.x, y: d.y, width: d.width, height: d.height
            )
        }
        let savedImgs = images.map { i in
            SavedImageFrame(
                id: i.id, filePath: i.filePath, displayName: i.displayName,
                x: i.x, y: i.y, width: i.width, height: i.height
            )
        }
        let savedSections = sections.map { s in
            SavedSection(
                id: s.id, title: s.title,
                x: s.x, y: s.y, width: s.width, height: s.height,
                routeIds: s.routeIds, documentIds: s.documentIds, imageIds: s.imageIds
            )
        }
        return CanvasSnapshot(
            routes: savedRoutes,
            documents: savedDocs,
            images: savedImgs,
            bindings: bindings,
            primaryBindingId: primaryBindingId,
            cameraX: camera.map { Double($0.origin.x) },
            cameraY: camera.map { Double($0.origin.y) },
            cameraZoom: camera.map { Double($0.zoom) },
            sections: savedSections.isEmpty ? nil : savedSections,
            styling: styling
        )
    }

    /// Replace the flat slots with a snapshot's contents. Caller is responsible for
    /// adjusting `activeCanvasId` and (separately) the WKWebView pool + camera.
    func restoreSnapshot(_ snap: CanvasSnapshot) {
        routes = snap.routes.map { sr in
            var route = RouteFrame(
                id: UUID(),
                path: sr.path,
                serverBindingId: sr.serverBindingId,
                x: sr.x, y: sr.y, width: sr.width, height: sr.height,
                zIndex: 0,
                displayName: sr.displayName,
                urlPath: sr.urlPath
            )
            route.captureDelay = sr.captureDelay
            route.captureDelaySource = sr.captureDelaySource
            route.isAnimatedDetected = sr.isAnimatedDetected
            return route
        }
        documents = snap.documents.map { sd in
            MarkdownFrame(
                id: sd.id, filePath: sd.filePath,
                x: sd.x, y: sd.y, width: sd.width, height: sd.height,
                displayName: sd.displayName
            )
        }
        images = snap.images.map { si in
            ImageFrame(
                id: si.id, filePath: si.filePath,
                x: si.x, y: si.y, width: si.width, height: si.height,
                displayName: si.displayName
            )
        }
        sections = (snap.sections ?? []).map { ss in
            CanvasSection(
                id: ss.id, title: ss.title,
                x: ss.x, y: ss.y, width: ss.width, height: ss.height,
                routeIds: ss.routeIds, documentIds: ss.documentIds, imageIds: ss.imageIds
            )
        }
        bindings = snap.bindings
        primaryBindingId = snap.primaryBindingId
        styling = snap.styling ?? .canonicalDefault
        screenshots = [:]   // screenshot file URLs survive on disk and re-attach on capture
        undoManager.removeAllActions()
    }

    /// Undo manager for canvas operations (move, resize, add, remove).
    let undoManager = UndoManager()

    // MARK: - Binding lookup

    /// Binding by id, or the primary if id is nil. Returns nil only when the document
    /// has no bindings at all (demo mode or fresh launch before any connect).
    func binding(id: UUID?) -> ServerBinding? {
        if let id, let match = bindings.first(where: { $0.id == id }) { return match }
        if let primary = primaryBindingId, let match = bindings.first(where: { $0.id == primary }) { return match }
        return bindings.first
    }

    /// Resolve the URL for a route by combining its binding's origin with the route's
    /// path (or urlPath override for dynamic segments). This is the route-aware shape —
    /// new callers should use it instead of url(forPath:).
    func url(for route: RouteFrame) -> URL? {
        // Absolute paths (https://example.com, the demo screenshots) bypass the binding.
        if route.path.hasPrefix("http://") || route.path.hasPrefix("https://") {
            return URL(string: route.path)
        }
        guard let binding = binding(id: route.serverBindingId) else { return nil }
        let suffix = route.urlPath
            ?? (route.path.range(of: " (").map { String(route.path[..<$0.lowerBound]) } ?? route.path)
        return URL(string: binding.origin.absoluteString + suffix)
    }

    /// Path-only URL resolver. Used by callers that don't have a RouteFrame in scope
    /// (URL-bar edits where the user types an arbitrary path). Resolves against the
    /// primary binding's origin. Returns nil while in demo / pre-connect.
    func url(forPath path: String, bindingId: UUID? = nil) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard let binding = binding(id: bindingId) else { return nil }
        if let route = routes.first(where: { $0.path == path }), let urlPath = route.urlPath {
            return URL(string: binding.origin.absoluteString + urlPath)
        }
        let cleaned = path.range(of: " (").map { String(path[..<$0.lowerBound]) } ?? path
        return URL(string: binding.origin.absoluteString + cleaned)
    }

    /// Hardcoded routes for Stage 2 testing. Centered around (25000, 25000) in a grid layout.
    static func withHardcodedRoutes() -> DocumentModel {
        let model = DocumentModel()
        let spacing: CGFloat = 100
        let desktopW: CGFloat = 1280
        let desktopH: CGFloat = 800

        // 3 columns, 2 rows. Last slot is a mobile frame to prove variable sizing.
        let col0: CGFloat = 24000
        let col1: CGFloat = col0 + desktopW + spacing
        let col2: CGFloat = col1 + desktopW + spacing
        let row0: CGFloat = 24500
        let row1: CGFloat = row0 + desktopH + spacing

        model.routes = [
            RouteFrame(id: UUID(), path: "/", x: col0, y: row0, width: desktopW, height: desktopH, zIndex: 0),
            RouteFrame(id: UUID(), path: "/dashboard", x: col1, y: row0, width: desktopW, height: desktopH, zIndex: 0),
            RouteFrame(id: UUID(), path: "/settings", x: col2, y: row0, width: desktopW, height: desktopH, zIndex: 0),
            RouteFrame(id: UUID(), path: "/profile", x: col0, y: row1, width: desktopW, height: desktopH, zIndex: 0),
            RouteFrame(id: UUID(), path: "/about", x: col1, y: row1, width: desktopW, height: desktopH, zIndex: 0),
            RouteFrame(id: UUID(), path: "/ (mobile)", x: col2, y: row1, width: 375, height: 812, zIndex: 0),
        ]
        return model
    }

    // MARK: - Demo Mode

    /// Load the demo project onto the canvas. Populates routes and screenshots
    /// from bundled resources. Called when no servers found and no saved sessions.
    ///
    /// Layout: "Responsive Cascade" — grouped by route, desktop + responsive variants side-by-side.
    ///   Row 1: Overview (desktop → tablet → mobile)
    ///   Row 2: Details (desktop → mobile) + Users (desktop)
    func loadDemoRoutes() {
        let frameH: CGFloat = 800
        let demoBase = "http://127.0.0.1:3000"

        // 6 frames with explicit positions — centred on (25000, 25000)
        let demoRoutes: [(path: String, displayName: String, width: CGFloat, x: CGFloat, y: CGFloat, screenshot: String)] = [
            // Row 1: Overview across 3 viewports
            ("\(demoBase)/overview",        "/overview",           1280, 23383, 24050, "overview-1280"),
            ("\(demoBase)/overview",        "/overview (tablet)",   768, 24763, 24050, "overview-768"),
            ("\(demoBase)/overview",        "/overview (mobile)",   375, 25631, 24050, "overview-375"),
            // Row 2: Details pair + Users
            ("\(demoBase)/details",         "/details",            1280, 23383, 25150, "details-1280"),
            ("\(demoBase)/details",         "/details (mobile)",    375, 24763, 25150, "details-375"),
            ("\(demoBase)/settings/users",  "/settings/users",     1280, 25338, 25150, "settings-users-1280"),
        ]

        var newRoutes: [RouteFrame] = []
        var newScreenshots: [UUID: URL] = [:]

        for route in demoRoutes {
            let id = UUID()
            newRoutes.append(RouteFrame(
                id: id,
                path: route.path,
                x: route.x,
                y: route.y,
                width: route.width,
                height: frameH,
                zIndex: 0,
                displayName: route.displayName
            ))

            if let url = Bundle.main.url(forResource: route.screenshot, withExtension: "jpg", subdirectory: "DemoScreenshots") {
                newScreenshots[id] = url
            }
        }

        staggerTask?.cancel()
        self.routes = newRoutes
        self.screenshots = newScreenshots
        undoManager.removeAllActions()

        if newScreenshots.count < demoRoutes.count {
            print("[Demo] WARNING: Only \(newScreenshots.count)/\(demoRoutes.count) demo screenshots found in bundle")
        }
    }

    // MARK: - Markdown document path mutation

    /// Re-point a markdown frame at a new on-disk path. Used by `MarkdownPathHealer`
    /// when an FSEvents burst reveals the underlying file was moved/renamed inside
    /// the project root. No-op if the id is unknown or the path didn't change.
    /// Returns true on a real mutation so callers can persist + breadcrumb.
    @discardableResult
    func updateDocumentPath(id: UUID, newPath: String) -> Bool {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return false }
        guard documents[idx].filePath != newPath else { return false }
        documents[idx].filePath = newPath
        return true
    }

    // MARK: - Route Status

    /// Idempotent status transition. No-op if the route is already in the target status.
    func setRouteStatus(id: UUID, status: RouteStatus) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else { return }
        guard routes[idx].status != status else { return }
        routes[idx].status = status
    }

    /// Remove a single dismissed route and clean up its screenshot.
    func dismissRemovedRoute(id: UUID) {
        guard let idx = routes.firstIndex(where: { $0.id == id && $0.isRemoved }) else { return }
        let removedId = routes[idx].id
        routes.remove(at: idx)
        if let url = screenshots[removedId] {
            try? FileManager.default.removeItem(at: url)
        }
        screenshots.removeValue(forKey: removedId)
    }

    /// Remove all routes currently marked as removed and clean up their screenshots.
    func dismissAllRemovedRoutes() {
        let removedIds = routes.filter(\.isRemoved).map(\.id)
        for id in removedIds {
            if let url = screenshots[id] {
                try? FileManager.default.removeItem(at: url)
            }
            screenshots.removeValue(forKey: id)
        }
        routes.removeAll(where: \.isRemoved)
    }

    /// Number of routes currently in the removed state.
    var removedRouteCount: Int {
        routes.filter(\.isRemoved).count
    }

    /// TTL and cap for removed routes. Prevents unbounded screenshot cache growth.
    private static let maxRemovedFrames = 20
    private static let removedTTL: TimeInterval = 30 * 60 // 30 minutes

    /// Evict removed routes that exceed the TTL or cap. Called during mergeDiscoveredRoutes().
    private func cleanupStaleRemovedRoutes() {
        let now = Date()
        // Expire by TTL
        let expired = routes.filter { route in
            guard let removedAt = route.removedAt else { return false }
            return now.timeIntervalSince(removedAt) > Self.removedTTL
        }.map(\.id)
        for id in expired { dismissRemovedRoute(id: id) }

        // Cap by count (oldest first)
        let removed = routes.filter(\.isRemoved).sorted { ($0.removedAt ?? .distantPast) < ($1.removedAt ?? .distantPast) }
        if removed.count > Self.maxRemovedFrames {
            let excess = removed.prefix(removed.count - Self.maxRemovedFrames)
            for route in excess { dismissRemovedRoute(id: route.id) }
        }
    }

    // MARK: - Route Discovery Integration

    /// Stagger interval between adding each new route frame to the canvas.
    private static let staggerInterval: TimeInterval = 0.15

    /// Cancel any in-flight staggered additions (e.g. if re-discovery is triggered).
    private var staggerTask: Task<Void, Never>?

    /// Merge discovered routes onto the canvas. Preserves positions of existing routes,
    /// removes orphans immediately, then adds new routes one at a time with a short delay
    /// so WKWebView pool and screenshots don't get overwhelmed.
    ///
    /// C0: route discovery is scoped to the primary binding (the project we have a
    /// projectDir for). Dedupe/orphan logic keys by `(serverBindingId, path)` not just
    /// path — `/login` on :3000 is not the same route as `/login` on :3001. Secondary
    /// bindings' routes are added via MCP / manual add and live outside this merge.
    func mergeDiscoveredRoutes(_ discovered: [DiscoveredRoute]) {
        staggerTask?.cancel()

        let scopeBindingId = primaryBindingId
        let discoveredPaths = Set(discovered.map(\.label))

        // Auto-restore: un-remove SCOPED routes whose source files reappeared
        for i in routes.indices where routes[i].serverBindingId == scopeBindingId
            && routes[i].isRemoved && discoveredPaths.contains(routes[i].path) {
            routes[i].status = .active
            print("[RouteDiscovery] Auto-restored route: \(routes[i].path)")
        }

        // Build the lookup after restoring statuses so recovered frames retain their IDs and positions.
        let scopedRoutes = routes.filter { $0.serverBindingId == scopeBindingId }
        let existingByPath = Dictionary(scopedRoutes.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })

        // Keep active scoped routes that still exist on disk (preserve user positions)
        let kept: [RouteFrame] = existingByPath.values.filter {
            discoveredPaths.contains($0.path) && !$0.isRemoved
        }
        let keptPaths = Set(kept.map(\.path))

        // Mark scoped orphans as removed (keep in array with their screenshot for ghost display)
        let orphanedPaths = Set(scopedRoutes.filter { !$0.isRemoved }.map(\.path)).subtracting(discoveredPaths)
        for path in orphanedPaths {
            if let route = existingByPath[path], !route.isRemoved {
                setRouteStatus(id: route.id, status: .removed(at: Date(), cause: .discovery))
                print("[RouteDiscovery] Marked route as removed: \(path)")
            }
        }

        // Combine: active kept SCOPED routes + all currently-removed scoped routes (ghosts)
        // + every route bound to a DIFFERENT binding (untouched by this discovery pass).
        let removedScoped = routes.filter { $0.serverBindingId == scopeBindingId && $0.isRemoved }
        let otherBindingRoutes = routes.filter { $0.serverBindingId != scopeBindingId }
        routes = kept + removedScoped + otherBindingRoutes

        // Clean up stale removed routes (TTL + cap)
        cleanupStaleRemovedRoutes()

        // Find genuinely new routes and compute their grid positions
        let newRoutes = discovered.filter { !keptPaths.contains($0.label) }
        let gridFrames = layoutNewRoutes(newRoutes, avoiding: kept)

        print("[RouteDiscovery] Merging: \(kept.count) kept, \(gridFrames.count) new, \(orphanedPaths.count) newly removed, \(removedScoped.count) total ghosts")

        let totalActive = kept.count + gridFrames.count
        if totalActive > 0 {
            AnalyticsService.shared.capture(.routesLoaded, properties: [
                "count": totalActive,
            ])
        }

        // Stagger new route additions so the canvas loads them one by one
        guard !gridFrames.isEmpty else { return }
        staggerTask = Task { @MainActor [weak self] in
            for frame in gridFrames {
                guard !Task.isCancelled, let self else { return }
                self.routes.append(frame)
                try? await Task.sleep(nanoseconds: UInt64(Self.staggerInterval * 1_000_000_000))
            }
        }
    }

    /// Lay out new routes in a horizontal row to the right of existing frames (Figma-style).
    /// Avoids colliding with existing frames that users may have repositioned.
    private func layoutNewRoutes(_ newRoutes: [DiscoveredRoute], avoiding existing: [RouteFrame]) -> [RouteFrame] {
        guard !newRoutes.isEmpty else { return [] }

        let frameWidth: CGFloat = 1280
        let frameHeight: CGFloat = 800
        let spacing: CGFloat = 100

        // Starting position — to the right of existing frames, or centred on canvas
        var nextX: CGFloat
        let startY: CGFloat

        if existing.isEmpty {
            nextX = CanvasCamera.canvasCenter.x - frameWidth / 2
            startY = CanvasCamera.canvasCenter.y - frameHeight / 2
        } else {
            // Place to the right of the rightmost existing frame
            let maxRight = existing.map { $0.x + $0.width }.max() ?? CanvasCamera.canvasCenter.x
            nextX = maxRight + spacing
            // Vertically centre against the bounding box of existing frames
            let minY = existing.map(\.y).min() ?? CanvasCamera.canvasCenter.y
            let maxBottom = existing.map { $0.y + $0.effectiveHeight }.max() ?? (minY + frameHeight)
            startY = minY + (maxBottom - minY - frameHeight) / 2
        }

        // Build occupied rects from existing frames for collision detection
        let occupied = existing.map { route in
            CGRect(x: route.x, y: route.y, width: route.width, height: route.effectiveHeight)
        }

        var result: [RouteFrame] = []

        for route in newRoutes {
            var candidateRect = CGRect(x: nextX, y: startY, width: frameWidth, height: frameHeight)

            // Skip right if colliding with existing frames
            while occupied.contains(where: { $0.intersects(candidateRect) }) {
                candidateRect.origin.x += frameWidth + spacing
            }

            let frame = RouteFrame(
                id: UUID(),
                path: route.label,
                serverBindingId: primaryBindingId,
                x: candidateRect.origin.x,
                y: candidateRect.origin.y,
                width: frameWidth,
                height: frameHeight,
                zIndex: 0,
                urlPath: route.label == route.urlPath ? nil : route.urlPath
            )
            result.append(frame)
            nextX = candidateRect.origin.x + frameWidth + spacing
        }

        return result
    }
}
