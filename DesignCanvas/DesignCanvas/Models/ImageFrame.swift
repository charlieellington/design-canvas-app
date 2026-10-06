// A static image rendered on the canvas (PNG, JPG, SVG, HEIC). filePath is absolute.
// Like MarkdownFrame, id is persisted — the same image can appear twice (e.g., a hero
// image referenced from two different moodboard arrangements).

import Foundation

struct ImageFrame: Identifiable {
    let id: UUID
    var filePath: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 600
    var height: CGFloat = 400
    var displayName: String?

    var labelText: String {
        if let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return (filePath as NSString).lastPathComponent
    }

    var effectiveHeight: CGFloat { height }
}
