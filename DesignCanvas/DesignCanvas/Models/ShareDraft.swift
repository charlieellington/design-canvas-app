// Cross-stage §6 — Stage 16a → 16b handoff value. The Create Link button in
// Stage 16a's action cluster builds this struct, and Stage 16b uploads exactly
// the JPEG bytes it carries. NO re-capture between preview and upload. Each
// frame in `frames` is the bitmap CaptureOrchestrator's last successful run
// produced — the same pixels the recipient preview card already showed.
//
// `idempotencyKey` is persisted by Stage 16b's PendingUploadStore so retries
// don't double-create shares.

import AppKit
import Foundation

/// Frame discriminator + Mac-generated client UUID. Same shape as the
/// cross-stage §1 `FrameAnchor` (kind + clientFrameId). Stage 16a uses
/// `FrameRef` instead of raw `routeID` so markdown / image frames round-trip
/// alongside routes.
struct FrameRef: Hashable, Codable {
    let kind: FrameKind
    let id: UUID

    enum FrameKind: String, Codable {
        case route, markdown, image
    }
}

/// World-space geometry per frame at Share Mode exit.
struct FrameGeometry: Hashable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static func from(rect: CGRect) -> FrameGeometry {
        FrameGeometry(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height),
        )
    }
}

/// Initial-view contract (cross-stage §6) — world-space CENTRE point + bounded
/// scale. Stage 15's `/share/[id]` hydrates from this exact shape.
struct InitialView: Hashable, Codable {
    var x: Double
    var y: Double
    var scale: Double  // bounded 0.01..100; Stage 15 clamps to MIN_SCALE/MAX_SCALE
}

/// Per-frame source context for the upload. Includes route path / display
/// name / content hash so Stage 16b's PUT /image carries the right metadata
/// without re-querying the document model.
struct ShareDraftFrame {
    let ref: FrameRef
    let image: NSImage
    let geometry: FrameGeometry
    let viewport: CGSize
    let sourceIdentifier: String
    let displayName: String?
    let contentHash: String?
}

/// The complete Stage 16a → 16b handoff value. Built when the user clicks
/// Create Link; consumed by `ShareUploadOrchestrator` in 16b.
struct ShareDraft {
    let frames: [ShareDraftFrame]
    let viewport: CGSize          // recipient-target viewport (capture viewport)
    let backingScale: CGFloat     // retina factor at capture time
    let initialView: InitialView
    let styling: StylingConfig
    let title: String?
    let defaultTitle: String?     // active canvas name when ≠ "Working Canvas"
    let idempotencyKey: UUID
}
