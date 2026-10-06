// A markdown document rendered on the canvas as a dark-themed "knowledge card" frame.
// filePath is absolute. Unlike RouteFrame, id is persisted — two markdown frames may
// legitimately point at the same file (e.g., the same spec open twice at different sizes).

import Foundation

struct MarkdownFrame: Identifiable {
    let id: UUID
    var filePath: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 700
    var height: CGFloat = 800
    var displayName: String?

    var labelText: String {
        if let name = displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return (filePath as NSString).lastPathComponent
    }

    var effectiveHeight: CGFloat { height }
}
