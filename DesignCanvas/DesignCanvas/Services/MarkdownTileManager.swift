// Caps the number of live markdown WKWebViews to prevent memory blow-up. Parallel to
// TileLifecycle (which manages the route pool) but simpler: no screenshot fallback, no
// pool reuse — just an LRU cap with "click to load" placeholders for excess frames.
//
// Each live markdown WKWebView costs ~15 MB. 12 live is comfortable on modern Macs while
// leaving headroom for the 6–18 route WKWebViews TileLifecycle manages.

import AppKit

final class MarkdownTileManager {

    /// Maximum number of live markdown WKWebViews at once.
    static let maxLive: Int = 12

    /// Ordered: head = most recently made live. Tail = eviction candidate.
    private var lru: [(id: UUID, container: CanvasFrameContainer)] = []

    /// Mark a markdown frame as visible/interacted. Promotes to live if it was a placeholder,
    /// moves to head of LRU. Evicts tail if over cap.
    func touch(id: UUID, container: CanvasFrameContainer) {
        if let idx = lru.firstIndex(where: { $0.id == id }) {
            let entry = lru.remove(at: idx)
            lru.insert(entry, at: 0)
            if container.isMarkdownPlaceholder {
                container.promoteMarkdownFromPlaceholder()
            }
            return
        }
        // New entry — evict if needed
        while lru.count >= Self.maxLive, let oldest = lru.popLast() {
            oldest.container.showMarkdownPlaceholder()
        }
        if container.isMarkdownPlaceholder {
            container.promoteMarkdownFromPlaceholder()
        }
        lru.insert((id, container), at: 0)
    }

    /// Remove a frame from tracking (called when a markdown container is removed from canvas).
    func unregister(id: UUID) {
        lru.removeAll { $0.id == id }
    }

    /// Recompute based on viewport visibility. Called on scroll/zoom changes.
    /// Visible markdown frames get touch()'d (promoted if placeholder). Frames far from the
    /// viewport are demoted if over cap.
    func recalculate(visibleRect: CGRect, containers: [CanvasFrameContainer]) {
        let markdownContainers = containers.filter { $0.kind == .markdown }
        // Visible markdown — sort by distance to viewport centre, nearest first.
        let centre = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let visible = markdownContainers.filter { $0.frame.intersects(visibleRect) }
            .sorted { a, b in distance(a.frame, centre) < distance(b.frame, centre) }
        for c in visible {
            touch(id: c.routeId, container: c)
        }
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let cx = rect.midX - point.x
        let cy = rect.midY - point.y
        return cx * cx + cy * cy
    }
}
