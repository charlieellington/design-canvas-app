// Serialisable canvas state for session persistence. One JSON file per project directory,
// keyed by SHA256 hash of the project path. Stores route positions and sizes — screenshots
// are re-captured on launch, not stored.

import Foundation

struct CanvasState: Codable {
    let projectDir: String
    let projectName: String
    let serverPort: Int
    let routes: [SavedRoute]
    // Optional for backwards compat — old session files decode these as nil.
    let documents: [SavedMarkdownFrame]?
    let images: [SavedImageFrame]?
    // C0 additions — all optional so v1 session files still decode cleanly.
    let schemaVersion: Int?         // ≥2 routes carry serverBindingId; ≥3 canvases persisted; ≥4 sections persisted
    let bindings: [ServerBinding]?  // server bindings tracked on this canvas
    let primaryBindingId: UUID?     // which binding is the primary (drives session identity)
    // A1 — multi-canvas. v3+ files carry the canvases array + per-canvas snapshots
    // for everything that isn't the active canvas. v1/v2 files migrate transparently
    // (single Working Canvas with the flat fields above as its snapshot).
    let canvases: [Canvas]?
    let activeCanvasId: UUID?
    let canvasSnapshots: [String: CanvasSnapshot]?  // UUID encoded as String (JSON object keys)
    /// v4 — sections on the active canvas. Optional so v1/v2/v3 files still decode.
    let sections: [SavedSection]?
    /// Active-canvas camera. Mirrors the per-CanvasSnapshot triple so cold-open
    /// restores zoom + scroll instead of dropping the user at canvas origin. All
    /// optional so older files still decode and missing fields fall through to
    /// whatever camera state is current on load.
    let cameraX: Double?
    let cameraY: Double?
    let cameraZoom: Double?
    /// Stage 14b — active-canvas styling. Optional so v1–v4 files still decode
    /// cleanly; missing styling falls through to StylingConfig.canonicalDefault
    /// on restore.
    let styling: StylingConfig?

    init(
        projectDir: String,
        projectName: String,
        serverPort: Int,
        routes: [SavedRoute],
        documents: [SavedMarkdownFrame]?,
        images: [SavedImageFrame]?,
        schemaVersion: Int? = 4,
        bindings: [ServerBinding]? = nil,
        primaryBindingId: UUID? = nil,
        canvases: [Canvas]? = nil,
        activeCanvasId: UUID? = nil,
        canvasSnapshots: [String: CanvasSnapshot]? = nil,
        sections: [SavedSection]? = nil,
        cameraX: Double? = nil,
        cameraY: Double? = nil,
        cameraZoom: Double? = nil,
        styling: StylingConfig? = nil
    ) {
        self.projectDir = projectDir
        self.projectName = projectName
        self.serverPort = serverPort
        self.routes = routes
        self.documents = documents
        self.images = images
        self.schemaVersion = schemaVersion
        self.bindings = bindings
        self.primaryBindingId = primaryBindingId
        self.canvases = canvases
        self.activeCanvasId = activeCanvasId
        self.canvasSnapshots = canvasSnapshots
        self.sections = sections
        self.cameraX = cameraX
        self.cameraY = cameraY
        self.cameraZoom = cameraZoom
        self.styling = styling
    }
}

struct SavedRoute: Codable {
    let path: String
    let urlPath: String?
    let displayName: String?
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    // C0: optional so v1 session files still decode. v1→v2 migration back-fills.
    let serverBindingId: UUID?
    // Stage 14.5a — per-route capture-delay persistence. All optional so pre-14.5a
    // session files decode without throwing keyNotFound (explicit init(from:) below).
    let captureDelay: TimeInterval?
    let captureDelaySource: CaptureDelaySource?
    let isAnimatedDetected: Bool

    init(
        path: String,
        urlPath: String?,
        displayName: String?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        serverBindingId: UUID? = nil,
        captureDelay: TimeInterval? = nil,
        captureDelaySource: CaptureDelaySource? = nil,
        isAnimatedDetected: Bool = false
    ) {
        self.path = path
        self.urlPath = urlPath
        self.displayName = displayName
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.serverBindingId = serverBindingId
        self.captureDelay = captureDelay
        self.captureDelaySource = captureDelaySource
        self.isAnimatedDetected = isAnimatedDetected
    }

    private enum CodingKeys: String, CodingKey {
        case path, urlPath, displayName, x, y, width, height
        case serverBindingId, captureDelay, captureDelaySource, isAnimatedDetected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.urlPath = try c.decodeIfPresent(String.self, forKey: .urlPath)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.x = try c.decode(CGFloat.self, forKey: .x)
        self.y = try c.decode(CGFloat.self, forKey: .y)
        self.width = try c.decode(CGFloat.self, forKey: .width)
        self.height = try c.decode(CGFloat.self, forKey: .height)
        self.serverBindingId = try c.decodeIfPresent(UUID.self, forKey: .serverBindingId)
        self.captureDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .captureDelay)
        self.captureDelaySource = try c.decodeIfPresent(CaptureDelaySource.self, forKey: .captureDelaySource)
        self.isAnimatedDetected = try c.decodeIfPresent(Bool.self, forKey: .isAnimatedDetected) ?? false
    }
}

// Unlike SavedRoute, id is persisted — two markdown/image frames may reference the
// same file, so filePath is not a stable identity.

struct SavedMarkdownFrame: Codable {
    let id: UUID
    let filePath: String
    let displayName: String?
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct SavedImageFrame: Codable {
    let id: UUID
    let filePath: String
    let displayName: String?
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}
