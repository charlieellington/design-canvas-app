// A named group of frames that live together on the canvas. Sections are rendered
// as a labelled rectangle behind the frames they contain, and can be removed as a
// unit — `removeSection(id:)` deletes the section AND every frame it references.
//
// In-memory form (`CanvasSection`) holds the live, observable shape used by views
// and the canvas manager. `SavedSection` is the Codable DTO used by session
// persistence — it mirrors the same fields but is decoupled from the runtime
// model, matching the SavedRoute / SavedMarkdownFrame / SavedImageFrame pattern.

import Foundation

struct CanvasSection: Identifiable, Equatable {
    let id: UUID
    var title: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var routeIds: [UUID]
    var documentIds: [UUID]
    var imageIds: [UUID]

    init(
        id: UUID = UUID(),
        title: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        routeIds: [UUID] = [],
        documentIds: [UUID] = [],
        imageIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.routeIds = routeIds
        self.documentIds = documentIds
        self.imageIds = imageIds
    }
}

struct SavedSection: Codable {
    let id: UUID
    let title: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let routeIds: [UUID]
    let documentIds: [UUID]
    let imageIds: [UUID]
}
