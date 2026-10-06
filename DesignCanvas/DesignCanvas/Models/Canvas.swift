// A1 — Canvas metadata. The user-visible artifact: a named, stable surface that
// holds routes, documents, images, and the server bindings they're plugged into.
//
// Implementation note: this is metadata + snapshot ids, NOT the full
// @Observable class the plan originally specced. The flat DocumentModel slots
// stay; switching canvases serialises the current slots into the previous
// canvas's snapshot and restores the target canvas's snapshot. This keeps
// every existing call site of `document.routes` etc. working without a project-
// wide refactor.

import Foundation

struct Canvas: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let isDefault: Bool          // true only for Working Canvas
    var createdAt: Date
    var updatedAt: Date
    var shareId: String?
    var shareStatus: ShareStatus

    enum ShareStatus: String, Codable {
        case notShared, published, changesPending
    }

    init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        shareId: String? = nil,
        shareStatus: ShareStatus = .notShared
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.shareId = shareId
        self.shareStatus = shareStatus
    }

    static func defaultWorkingCanvas() -> Canvas {
        Canvas(id: UUID(), name: "Working Canvas", isDefault: true)
    }
}

/// On-disk snapshot of one canvas's contents. The active canvas's snapshot is
/// kept in-memory as the flat DocumentModel slots; only inactive canvases are
/// serialised to this DTO. SessionPersistence persists all snapshots alongside
/// the canvases array.
struct CanvasSnapshot: Codable {
    var routes: [SavedRoute]
    var documents: [SavedMarkdownFrame]
    var images: [SavedImageFrame]
    var bindings: [ServerBinding]
    var primaryBindingId: UUID?
    /// Camera state at the time of snapshot. Optional — when nil, switching
    /// preserves the current camera (no jump). Future A1 work makes this required.
    var cameraX: Double?
    var cameraY: Double?
    var cameraZoom: Double?
    /// Sections grouping frames on this canvas. Optional for back-compat — snapshots
    /// written before sections existed decode this as nil.
    var sections: [SavedSection]?
    /// Stage 14b — per-canvas styling snapshot. Optional for back-compat with
    /// pre-14b session files; nil decodes to `StylingConfig.canonicalDefault` on
    /// restore.
    var styling: StylingConfig?
}
