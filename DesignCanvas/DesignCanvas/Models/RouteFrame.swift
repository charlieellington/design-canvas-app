// A single route displayed on the canvas. Width is the authored viewport width (1280 desktop,
// 375 mobile, etc.). Height is always an explicit value set by the user or default (800px).
// Use "Fit to Content" to measure page scroll height and set it as the new fixed height.

import Foundation

/// Why a route was marked as removed from the canvas.
enum RemovalCause {
    case discovery   // File watcher + route discovery detected the source file was deleted
    case http404     // WKWebView got 404 from the dev server (fallback detection)
}

/// Whether a route's source file still exists on disk.
/// Not persisted — on restart, discovery re-runs and marks stale routes fresh.
enum RouteStatus: Equatable {
    case active
    case removed(at: Date, cause: RemovalCause)

    static func == (lhs: RouteStatus, rhs: RouteStatus) -> Bool {
        switch (lhs, rhs) {
        case (.active, .active): return true
        case (.removed, .removed): return true
        default: return false
        }
    }
}

/// Whether a route's `captureDelay` was set by the auto-detect probe (Stage 14.5b)
/// or by the user via the popover. Lets the UI distinguish "the system chose
/// this for you" from "you set this explicitly" without relying on a brittle
/// `delay == 3.0` equality check.
enum CaptureDelaySource: String, Codable {
    case auto, user
}

struct RouteFrame: Identifiable {
    let id: UUID
    var path: String

    /// Which ServerBinding this route is plugged into. Optional only because v1
    /// session files (pre-C0) decode without it; v1→v2 migration back-fills the
    /// synthesized binding's id. After migration, every live route carries a binding —
    /// callers should treat nil as "use the document's primary binding" only as a
    /// last-resort fallback. See DocumentModel.url(for:).
    var serverBindingId: UUID?

    /// Stage 14.5a — per-route extra delay between DOM-settle and snapshot.
    /// `nil` preserves the existing 3-tier chain. `0` is a user-explicit "no
    /// delay". `> 0` is either the user's choice or the Stage 14.5b auto-
    /// detect probe's `3.0` default. Persisted via SavedRoute.
    var captureDelay: TimeInterval?

    /// Auto vs user origin for `captureDelay`. Nil whenever `captureDelay` is nil.
    var captureDelaySource: CaptureDelaySource?

    /// Most-recent probe result (Stage 14.5b). UI-hint only; substrate ignores.
    var isAnimatedDetected: Bool = false

    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 1280
    var height: CGFloat = 800
    var zIndex: Int

    /// User-set custom name for the frame. Nil means show the route path.
    var displayName: String?

    /// URL path with dynamic segments replaced by mock values (e.g. /blog/mock-slug).
    /// Nil when the path has no dynamic segments (urlPath == path).
    var urlPath: String?

    /// What the label above the frame should display: custom name if set, otherwise the route path.
    var labelText: String {
        if let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return path
    }

    /// Whether this route's source file has been removed from the project.
    /// Transient — not persisted to session files. Set by DocumentModel.mergeDiscoveredRoutes().
    var status: RouteStatus = .active

    /// Convenience: true when the route file no longer exists on disk.
    var isRemoved: Bool {
        if case .removed = status { return true }
        return false
    }

    /// When the route was marked as removed. Nil if active.
    var removedAt: Date? {
        if case .removed(let date, _) = status { return date }
        return nil
    }

    /// Returns the height to use for layout. Trivial pass-through kept for call-site compatibility.
    var effectiveHeight: CGFloat { height }
}
