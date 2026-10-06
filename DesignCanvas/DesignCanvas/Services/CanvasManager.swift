// Bridges the HTTP API to canvas state. Thread-safe boundary — HTTP handlers run on
// Swifter's background thread, all canvas/UI updates dispatch through @MainActor.

import AppKit
import Foundation

@MainActor
class CanvasManager {

    let document: DocumentModel
    let screenshotService: ScreenshotService

    init(document: DocumentModel, screenshotService: ScreenshotService) {
        self.document = document
        self.screenshotService = screenshotService
    }

    // MARK: - Route queries

    var routeData: [[String: Any]] {
        document.routes.map { route in
            var dict: [String: Any] = [
                "id": route.id.uuidString,
                "path": route.path,
                "x": route.x,
                "y": route.y,
                "width": route.width,
                "height": route.height,
            ]
            dict["status"] = route.isRemoved ? "removed" : "active"
            if let url = document.screenshots[route.id] {
                dict["screenshotPath"] = url.path
            }
            // C0: expose which dev server this route is plugged into. Agents disambiguate
            // duplicate paths across servers via these fields. Resolved binding may differ
            // from the saved serverBindingId after a port-move; surface the live values.
            if let route = document.routes.first(where: { $0.id == route.id }),
               let binding = document.binding(id: route.serverBindingId) {
                dict["serverId"] = binding.id.uuidString
                if let port = binding.port { dict["serverPort"] = port }
                dict["serverProject"] = binding.displayName
            }
            return dict
        }
    }

    /// Per-binding summary for the MCP `list_servers` tool + HTTP /servers endpoint.
    var serverData: [[String: Any]] {
        document.bindings.map { binding in
            var dict: [String: Any] = [
                "serverId": binding.id.uuidString,
                "projectName": binding.displayName,
                "status": binding.status.rawValue,
            ]
            if let port = binding.port { dict["port"] = port }
            if let dir = binding.projectDir { dict["projectDir"] = dir }
            dict["origin"] = binding.origin.absoluteString
            dict["isPrimary"] = (binding.id == document.primaryBindingId)
            return dict
        }
    }

    // MARK: - Add route

    /// Disambiguation result from addRoute when the caller didn't specify a server
    /// and the canvas has more than one binding.
    struct ServerDisambiguationError: Error {
        let availableServers: [(id: UUID, port: Int?, projectName: String, projectDir: String?)]
    }

    /// Placement hint for auto-positioning. `.rightOfLast` preserves the legacy
    /// "stack next to the last frame of this kind" behaviour. `.newRow` always
    /// drops to a fresh row below every existing frame, even when right-stacking
    /// wouldn't collide.
    enum Placement {
        case rightOfLast
        case newRow
    }

    enum FrameKind {
        case route, document, image
    }

    /// Add a route. `port` and `serverId` are optional disambiguators when the canvas
    /// has multiple bindings. Throws ServerDisambiguationError when ambiguous.
    func addRoute(
        path: String,
        x: CGFloat?,
        y: CGFloat?,
        width: CGFloat?,
        height: CGFloat?,
        port: Int? = nil,
        serverId: UUID? = nil,
        placement: Placement = .rightOfLast
    ) throws -> UUID {
        let w = width ?? 1280
        let h = height ?? 800

        let (autoX, autoY) = nextAutoPosition(width: w, height: h, kind: .route, placement: placement)

        // Resolve target binding.
        let targetBindingId = try resolveBinding(port: port, serverId: serverId)

        let id = UUID()
        let route = RouteFrame(
            id: id,
            path: path,
            serverBindingId: targetBindingId,
            x: x ?? autoX,
            y: y ?? autoY,
            width: w,
            height: h,
            zIndex: 0
        )
        document.routes.append(route)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "add_route", message: path)
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return id
    }

    /// Resolve which binding a new route should attach to. Returns nil only when the
    /// document has zero bindings (demo mode / pre-connect). Throws when the canvas
    /// has >1 binding and neither port nor serverId disambiguates.
    private func resolveBinding(port: Int?, serverId: UUID?) throws -> UUID? {
        let bindings = document.bindings
        if bindings.isEmpty { return nil }

        if let serverId, bindings.contains(where: { $0.id == serverId }) {
            return serverId
        }
        if let port, let match = bindings.first(where: { $0.port == port }) {
            return match.id
        }
        if port != nil, serverId == nil {
            // Caller asked for a specific port but it isn't bound. Surface the available
            // bindings so callers (especially MCP/HTTP) can present a usable choice.
            throw ServerDisambiguationError(availableServers: bindings.map {
                (id: $0.id, port: $0.port, projectName: $0.displayName, projectDir: $0.projectDir)
            })
        }
        if bindings.count == 1 { return bindings[0].id }
        if let primary = document.primaryBindingId, bindings.contains(where: { $0.id == primary }) {
            return primary
        }
        throw ServerDisambiguationError(availableServers: bindings.map {
            (id: $0.id, port: $0.port, projectName: $0.displayName, projectDir: $0.projectDir)
        })
    }

    // MARK: - Remove route

    func removeRoute(path: String) -> Bool {
        if let index = document.routes.firstIndex(where: { $0.path == path }) {
            let id = document.routes[index].id
            document.routes.remove(at: index)
            if let screenshotURL = document.screenshots[id] {
                try? FileManager.default.removeItem(at: screenshotURL)
            }
            document.screenshots.removeValue(forKey: id)
            CrashReporter.shared.breadcrumb(category: "canvas", action: "remove_route", message: path)
            AppServices.shared.sessionPersistence.scheduleSave(
                document: document, port: AppServices.shared.devServer.port
            )
            return true
        }
        return false
    }

    func removeRoute(id: UUID) -> Bool {
        if let index = document.routes.firstIndex(where: { $0.id == id }) {
            let removedPath = document.routes[index].path
            document.routes.remove(at: index)
            // Delete screenshot file from disk before removing the reference
            if let screenshotURL = document.screenshots[id] {
                try? FileManager.default.removeItem(at: screenshotURL)
            }
            document.screenshots.removeValue(forKey: id)
            CrashReporter.shared.breadcrumb(category: "canvas", action: "remove_route", message: removedPath)
            AppServices.shared.sessionPersistence.scheduleSave(
                document: document, port: AppServices.shared.devServer.port
            )
            return true
        }
        return false
    }

    // MARK: - Update route

    /// Mutate an existing route's path. Used by "Pin URL as route" (chrome bar) and
    /// the MCP `update_route` tool. Clears `urlPath` (dynamic-segment override) since
    /// the new path may not have the same parameters. Persists via SessionPersistence.
    func updateRoute(id: UUID, newPath: String) -> Bool {
        guard let index = document.routes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let oldPath = document.routes[index].path
        document.routes[index].path = newPath
        document.routes[index].urlPath = nil
        // Drop any cached screenshot — it's stale at the old path.
        if let screenshotURL = document.screenshots[id] {
            try? FileManager.default.removeItem(at: screenshotURL)
        }
        document.screenshots.removeValue(forKey: id)
        CrashReporter.shared.breadcrumb(
            category: "canvas",
            action: "update_route",
            message: "\(oldPath) → \(newPath)"
        )
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return true
    }

    // MARK: - Document (markdown) CRUD

    var documentData: [[String: Any]] {
        document.documents.map { doc in
            let ext = (doc.filePath as NSString).pathExtension.lowercased()
            let kind = (ext == "html" || ext == "htm") ? "html" : "markdown"
            var dict: [String: Any] = [
                "id": doc.id.uuidString,
                "filePath": doc.filePath,
                "kind": kind,
                "x": doc.x,
                "y": doc.y,
                "width": doc.width,
                "height": doc.height,
            ]
            if let displayName = doc.displayName {
                dict["displayName"] = displayName
            }
            return dict
        }
    }

    /// Add a markdown document frame. Returns nil if the file is unreadable.
    func addDocument(
        filePath: String,
        x: CGFloat?,
        y: CGFloat?,
        width: CGFloat?,
        height: CGFloat?,
        placement: Placement = .rightOfLast
    ) -> UUID? {
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return nil
        }
        let w = width ?? 700
        let h = height ?? 800
        let (autoX, autoY) = nextAutoPosition(width: w, height: h, kind: .document, placement: placement)
        let id = UUID()
        let frame = MarkdownFrame(
            id: id,
            filePath: filePath,
            x: x ?? autoX,
            y: y ?? autoY,
            width: w,
            height: h,
            displayName: nil
        )
        document.documents.append(frame)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "add_document", message: filePath)
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return id
    }

    func removeDocument(id: UUID) -> Bool {
        if let index = document.documents.firstIndex(where: { $0.id == id }) {
            let removedPath = document.documents[index].filePath
            document.documents.remove(at: index)
            AppServices.shared.markdownPathHealer.forget(frameId: id)
            CrashReporter.shared.breadcrumb(category: "canvas", action: "remove_document", message: removedPath)
            AppServices.shared.sessionPersistence.scheduleSave(
                document: document, port: AppServices.shared.devServer.port
            )
            return true
        }
        return false
    }

    // MARK: - Image CRUD

    var imageData: [[String: Any]] {
        document.images.map { img in
            var dict: [String: Any] = [
                "id": img.id.uuidString,
                "filePath": img.filePath,
                "x": img.x,
                "y": img.y,
                "width": img.width,
                "height": img.height,
            ]
            if let displayName = img.displayName {
                dict["displayName"] = displayName
            }
            return dict
        }
    }

    func addImage(
        filePath: String,
        x: CGFloat?,
        y: CGFloat?,
        width: CGFloat?,
        height: CGFloat?,
        placement: Placement = .rightOfLast
    ) -> UUID? {
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return nil
        }
        let (w, h): (CGFloat, CGFloat)
        if let width, let height {
            (w, h) = (width, height)
        } else if let px = ImageDimensions.pixelSize(ofFileAt: filePath) {
            let fitted = ImageDimensions.fittedSize(for: px)
            (w, h) = (fitted.width, fitted.height)
        } else {
            (w, h) = (600, 400)
        }
        let (autoX, autoY) = nextAutoPosition(width: w, height: h, kind: .image, placement: placement)
        let id = UUID()
        let frame = ImageFrame(
            id: id,
            filePath: filePath,
            x: x ?? autoX,
            y: y ?? autoY,
            width: w,
            height: h,
            displayName: nil
        )
        document.images.append(frame)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "add_image", message: filePath)
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return id
    }

    func removeImage(id: UUID) -> Bool {
        if let index = document.images.firstIndex(where: { $0.id == id }) {
            let removedPath = document.images[index].filePath
            document.images.remove(at: index)
            CrashReporter.shared.breadcrumb(category: "canvas", action: "remove_image", message: removedPath)
            AppServices.shared.sessionPersistence.scheduleSave(
                document: document, port: AppServices.shared.devServer.port
            )
            return true
        }
        return false
    }

    // MARK: - Batch add

    /// A single item in an add-batch request. Routes carry `path` + optional server
    /// disambiguators; documents and images carry `filePath`. Width/height are
    /// optional — sensible defaults are used per kind.
    struct BatchItem {
        let kind: FrameKind
        let path: String?
        let filePath: String?
        let width: CGFloat?
        let height: CGFloat?
        let port: Int?
        let serverId: UUID?

        static func route(path: String, width: CGFloat? = nil, height: CGFloat? = nil, port: Int? = nil, serverId: UUID? = nil) -> BatchItem {
            BatchItem(kind: .route, path: path, filePath: nil, width: width, height: height, port: port, serverId: serverId)
        }
        static func document(filePath: String, width: CGFloat? = nil, height: CGFloat? = nil) -> BatchItem {
            BatchItem(kind: .document, path: nil, filePath: filePath, width: width, height: height, port: nil, serverId: nil)
        }
        static func image(filePath: String, width: CGFloat? = nil, height: CGFloat? = nil) -> BatchItem {
            BatchItem(kind: .image, path: nil, filePath: filePath, width: width, height: height, port: nil, serverId: nil)
        }
    }

    /// Layout strategy for arranging items in a batch.
    /// `.row` lays items left-to-right in a single row.
    /// `.pairsRows` places even-indexed items on the top row and odd-indexed items
    /// directly below — ideal for route/doc pairs in interleaved order.
    enum BatchLayout {
        case row
        case pairsRows
    }

    /// Result entry for one added frame in a batch.
    struct BatchResult {
        let id: UUID
        let type: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let path: String?
        let filePath: String?
    }

    /// Errors that abort a batch add. Validation runs before any frame is appended,
    /// so a batch either adds every item or none of them.
    enum BatchError: Error {
        case invalidItem(index: Int, reason: String)
        case fileNotReadable(index: Int, path: String)
        case serverAmbiguous(ServerDisambiguationError)
    }

    /// Add a batch of frames as a single layout decision. Either all items succeed or
    /// none of them are added. `originOverride` pins the top-left of the batch (used
    /// by `addSection` to place items inside a section's allocated space); when nil,
    /// the batch's origin is computed via `nextAutoPosition` with the given placement
    /// (default `.newRow` — batches always claim a fresh row by default).
    @discardableResult
    func addBatch(
        items: [BatchItem],
        layout: BatchLayout = .row,
        placement: Placement = .newRow,
        originOverride: CGPoint? = nil
    ) throws -> [BatchResult] {
        if items.isEmpty { return [] }

        // Resolve sizes per item and validate inputs up-front (no partial commits).
        var resolvedSizes: [(w: CGFloat, h: CGFloat)] = []
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .route:
                guard let p = item.path, p.hasPrefix("/") else {
                    throw BatchError.invalidItem(index: index, reason: "route requires a path starting with '/'")
                }
                resolvedSizes.append((item.width ?? 1280, item.height ?? 800))
            case .document:
                guard let p = item.filePath else {
                    throw BatchError.invalidItem(index: index, reason: "document requires filePath")
                }
                guard FileManager.default.isReadableFile(atPath: p) else {
                    throw BatchError.fileNotReadable(index: index, path: p)
                }
                resolvedSizes.append((item.width ?? 700, item.height ?? 800))
            case .image:
                guard let p = item.filePath else {
                    throw BatchError.invalidItem(index: index, reason: "image requires filePath")
                }
                guard FileManager.default.isReadableFile(atPath: p) else {
                    throw BatchError.fileNotReadable(index: index, path: p)
                }
                let (w, h): (CGFloat, CGFloat)
                if let iw = item.width, let ih = item.height {
                    (w, h) = (iw, ih)
                } else if let px = ImageDimensions.pixelSize(ofFileAt: p) {
                    let fitted = ImageDimensions.fittedSize(for: px)
                    (w, h) = (fitted.width, fitted.height)
                } else {
                    (w, h) = (600, 400)
                }
                resolvedSizes.append((w, h))
            }
        }

        // Pre-resolve any route server bindings so a misrouted route fails the whole batch
        // before we mutate state.
        var routeBindings: [Int: UUID?] = [:]
        for (index, item) in items.enumerated() where item.kind == .route {
            do {
                routeBindings[index] = try resolveBinding(port: item.port, serverId: item.serverId)
            } catch let err as ServerDisambiguationError {
                throw BatchError.serverAmbiguous(err)
            }
        }

        // Compute layout dimensions and the batch origin (once, with full knowledge).
        let totalWidth = resolvedSizes.reduce(0) { $0 + $1.w } + CGFloat(items.count - 1) * Self.frameGap
        let maxHeight = resolvedSizes.map(\.h).max() ?? 0
        let origin: CGPoint
        if let override = originOverride {
            origin = override
        } else {
            let (ox, oy) = nextAutoPosition(width: totalWidth, height: maxHeight, kind: .route, placement: placement)
            origin = CGPoint(x: ox, y: oy)
        }
        let positions = computeBatchPositions(resolvedSizes: resolvedSizes, layout: layout, origin: origin)

        // Materialise frames.
        var results: [BatchResult] = []
        for (index, item) in items.enumerated() {
            let (w, h) = resolvedSizes[index]
            let pos = positions[index]
            let id = UUID()
            switch item.kind {
            case .route:
                let route = RouteFrame(
                    id: id,
                    path: item.path ?? "/",
                    serverBindingId: routeBindings[index] ?? nil,
                    x: pos.x, y: pos.y, width: w, height: h, zIndex: 0
                )
                document.routes.append(route)
                results.append(BatchResult(id: id, type: "route", x: pos.x, y: pos.y, width: w, height: h, path: item.path, filePath: nil))
            case .document:
                let doc = MarkdownFrame(id: id, filePath: item.filePath ?? "", x: pos.x, y: pos.y, width: w, height: h, displayName: nil)
                document.documents.append(doc)
                results.append(BatchResult(id: id, type: "document", x: pos.x, y: pos.y, width: w, height: h, path: nil, filePath: item.filePath))
            case .image:
                let img = ImageFrame(id: id, filePath: item.filePath ?? "", x: pos.x, y: pos.y, width: w, height: h, displayName: nil)
                document.images.append(img)
                results.append(BatchResult(id: id, type: "image", x: pos.x, y: pos.y, width: w, height: h, path: nil, filePath: item.filePath))
            }
        }

        CrashReporter.shared.breadcrumb(category: "canvas", action: "add_batch", message: "n=\(items.count) layout=\(layout)")
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return results
    }

    /// Positions each item in a batch according to the chosen layout, anchored at origin.
    private func computeBatchPositions(
        resolvedSizes: [(w: CGFloat, h: CGFloat)],
        layout: BatchLayout,
        origin: CGPoint
    ) -> [CGPoint] {
        switch layout {
        case .row:
            var positions: [CGPoint] = []
            var x = origin.x
            for size in resolvedSizes {
                positions.append(CGPoint(x: x, y: origin.y))
                x += size.w + Self.frameGap
            }
            return positions
        case .pairsRows:
            // Even indices on the top row, odd indices directly underneath in the same column.
            let row0Height = stride(from: 0, to: resolvedSizes.count, by: 2)
                .map { resolvedSizes[$0].h }
                .max() ?? 0
            var positions = Array(repeating: CGPoint.zero, count: resolvedSizes.count)
            var x = origin.x
            var k = 0
            while k * 2 < resolvedSizes.count {
                let topIdx = k * 2
                let bottomIdx = k * 2 + 1
                let topW = resolvedSizes[topIdx].w
                let bottomW = bottomIdx < resolvedSizes.count ? resolvedSizes[bottomIdx].w : topW
                let columnW = max(topW, bottomW)
                positions[topIdx] = CGPoint(x: x, y: origin.y)
                if bottomIdx < resolvedSizes.count {
                    positions[bottomIdx] = CGPoint(x: x, y: origin.y + row0Height + Self.frameGap)
                }
                x += columnW + Self.frameGap
                k += 1
            }
            return positions
        }
    }

    // MARK: - Sections

    var sectionData: [[String: Any]] {
        document.sections.map { sec in
            [
                "id": sec.id.uuidString,
                "title": sec.title,
                "x": sec.x,
                "y": sec.y,
                "width": sec.width,
                "height": sec.height,
                "routeIds": sec.routeIds.map(\.uuidString),
                "documentIds": sec.documentIds.map(\.uuidString),
                "imageIds": sec.imageIds.map(\.uuidString),
            ]
        }
    }

    /// Add a section wrapping a freshly created batch of frames. Picks a clean origin
    /// below all existing content (default), lays the items out via the batch primitive,
    /// then wraps them in a labelled rectangle that auto-sizes to the contents with
    /// internal padding. Returns the section id alongside the per-frame results.
    struct SectionResult {
        let sectionId: UUID
        let frames: [BatchResult]
    }

    private static let sectionTitleHeight: CGFloat = 36
    private static let sectionPadding: CGFloat = 40

    @discardableResult
    func addSection(
        title: String,
        items: [BatchItem],
        layout: BatchLayout = .row,
        x: CGFloat? = nil,
        y: CGFloat? = nil
    ) throws -> SectionResult {
        // Choose where the section sits. If the caller pins an origin, use it; otherwise
        // drop into a fresh row below existing content (with extra breathing room).
        let sectionOrigin: CGPoint = {
            if let x, let y { return CGPoint(x: x, y: y) }
            let rects = allFrameRectsIncludingSections()
            if rects.isEmpty {
                return CGPoint(x: Self.canvasCenterX, y: Self.canvasCenterY)
            }
            let minX = rects.map(\.minX).min() ?? Self.canvasCenterX
            let maxY = rects.map(\.maxY).max() ?? Self.canvasCenterY
            return CGPoint(x: minX, y: maxY + Self.frameGap * 2)
        }()

        // Frames live inside the section, below its title bar and inside its padding.
        let framesOrigin = CGPoint(
            x: sectionOrigin.x + Self.sectionPadding,
            y: sectionOrigin.y + Self.sectionTitleHeight + Self.sectionPadding / 2
        )

        let results = try addBatch(items: items, layout: layout, placement: .newRow, originOverride: framesOrigin)

        // Compute the section's bbox from the materialised frames + chrome.
        let maxRight = results.map { $0.x + $0.width }.max() ?? framesOrigin.x
        let maxBottom = results.map { $0.y + $0.height }.max() ?? framesOrigin.y
        let sectionWidth = (maxRight - sectionOrigin.x) + Self.sectionPadding
        let sectionHeight = (maxBottom - sectionOrigin.y) + Self.sectionPadding

        let sectionId = UUID()
        let section = CanvasSection(
            id: sectionId,
            title: title,
            x: sectionOrigin.x,
            y: sectionOrigin.y,
            width: sectionWidth,
            height: sectionHeight,
            routeIds: results.filter { $0.type == "route" }.map(\.id),
            documentIds: results.filter { $0.type == "document" }.map(\.id),
            imageIds: results.filter { $0.type == "image" }.map(\.id)
        )
        document.sections.append(section)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "add_section", message: "\(title) (\(items.count) items)")
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return SectionResult(sectionId: sectionId, frames: results)
    }

    /// Remove a section AND every frame it references in one transaction. Frames'
    /// screenshots are cleaned up via the existing removeRoute path.
    @discardableResult
    func removeSection(id: UUID) -> Bool {
        guard let index = document.sections.firstIndex(where: { $0.id == id }) else { return false }
        let section = document.sections[index]
        for routeId in section.routeIds { _ = removeRoute(id: routeId) }
        for docId in section.documentIds { _ = removeDocument(id: docId) }
        for imgId in section.imageIds { _ = removeImage(id: imgId) }
        document.sections.remove(at: index)
        CrashReporter.shared.breadcrumb(category: "canvas", action: "remove_section", message: section.title)
        AppServices.shared.sessionPersistence.scheduleSave(
            document: document, port: AppServices.shared.devServer.port
        )
        return true
    }

    /// Same as `allFrameRects` but also considers existing section rects so a new
    /// section's auto-origin sits below previous sections too.
    private func allFrameRectsIncludingSections() -> [CGRect] {
        let frames = allFrameRects()
        let sections = document.sections.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        return frames + sections
    }

    // MARK: - Auto-position helpers

    static let canvasCenterX: CGFloat = 24000
    static let canvasCenterY: CGFloat = 24500
    static let frameGap: CGFloat = 100

    /// Computes a non-overlapping (x, y) for a new auto-positioned frame.
    /// Contract: returned position never overlaps any existing frame on the active canvas.
    /// `.rightOfLast` tries the legacy "right of last frame of same kind" position and
    /// only falls back to a new row if that position would collide. `.newRow` skips the
    /// candidate and always drops below the bbox of every existing frame.
    func nextAutoPosition(
        width: CGFloat,
        height: CGFloat,
        kind: FrameKind,
        placement: Placement = .rightOfLast
    ) -> (CGFloat, CGFloat) {
        let rects = allFrameRects()
        if rects.isEmpty {
            return (Self.canvasCenterX, Self.canvasCenterY)
        }
        if placement == .newRow {
            return positionInNewRow(rects: rects)
        }
        let candidate = rightOfLastCandidate(kind: kind, rects: rects)
        let candidateRect = CGRect(x: candidate.0, y: candidate.1, width: width, height: height)
        if rects.contains(where: { $0.intersects(candidateRect) }) {
            return positionInNewRow(rects: rects)
        }
        return candidate
    }

    private func allFrameRects() -> [CGRect] {
        let routeRects = document.routes.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let docRects = document.documents.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let imgRects = document.images.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return routeRects + docRects + imgRects
    }

    private func positionInNewRow(rects: [CGRect]) -> (CGFloat, CGFloat) {
        let minX = rects.map(\.minX).min() ?? Self.canvasCenterX
        let maxY = rects.map(\.maxY).max() ?? Self.canvasCenterY
        return (minX, maxY + Self.frameGap)
    }

    private func rightOfLastCandidate(kind: FrameKind, rects: [CGRect]) -> (CGFloat, CGFloat) {
        switch kind {
        case .route:
            if let last = document.routes.last {
                return (last.x + last.width + Self.frameGap, last.y)
            }
        case .document:
            if let last = document.documents.last {
                return (last.x + last.width + Self.frameGap, last.y)
            }
        case .image:
            if let last = document.images.last {
                return (last.x + last.width + Self.frameGap, last.y)
            }
        }
        // No frame of this kind exists yet — fall back to rightmost-of-any-kind.
        let maxRight = rects.map(\.maxX).max() ?? Self.canvasCenterX
        let rightmost = rects.first(where: { abs($0.maxX - maxRight) < 0.5 })
        return (maxRight + Self.frameGap, rightmost?.minY ?? Self.canvasCenterY)
    }

    // MARK: - Capture all screenshots

    func captureAll(ids: [UUID]? = nil) async -> [[String: String]] {
        // Resolve the working set of routes. nil/empty → every route (back-compat).
        // Subset mode skips the screenshot service entirely when every requested id
        // is already cached on disk — Pass 1 already does this trick internally.
        let workingRoutes: [RouteFrame]
        if let ids, !ids.isEmpty {
            let idSet = Set(ids)
            workingRoutes = document.routes.filter { idSet.contains($0.id) }
            let allCached = workingRoutes.allSatisfy { document.screenshots[$0.id] != nil }
            if allCached, !workingRoutes.isEmpty {
                return workingRoutes.compactMap { route in
                    guard let url = document.screenshots[route.id] else { return nil }
                    return ["path": route.path, "filePath": url.path]
                }
            }
        } else {
            workingRoutes = document.routes
        }

        // Demo mode is an offline fixture: return bundled images without loading any route URL.
        if AppServices.shared.demo.isInDemoMode {
            return workingRoutes.compactMap { route in
                guard let url = document.screenshots[route.id] else { return nil }
                return ["path": route.path, "filePath": url.path]
            }
        }

        // If a capture is already in progress (e.g. initial app launch capture),
        // wait for it to finish rather than re-triggering
        if screenshotService.isCaptureInProgress {
            while screenshotService.isCaptureInProgress {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } else {
            // No capture in progress — run a fresh one against the working set.
            await screenshotService.captureAllRoutes(subset: ids == nil ? nil : workingRoutes)
        }
        return workingRoutes.compactMap { route in
            guard let url = document.screenshots[route.id] else { return nil }
            return ["path": route.path, "filePath": url.path]
        }
    }
}
