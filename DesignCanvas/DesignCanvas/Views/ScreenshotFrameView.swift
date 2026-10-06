// Displays a cached screenshot image inside a CanvasFrameContainer. Loads from a file URL
// on disk (not in-memory NSImage) to keep memory usage low with many routes.
// Used for non-live frames — the foundation for Stage 5's LOD pattern.

import AppKit

class ScreenshotFrameView: NSView {

    private let imageView: NSImageView

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        self.imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Load and display a screenshot from a file URL on disk.
    func setScreenshot(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else {
            print("[ScreenshotFrameView] Failed to load image from \(fileURL.lastPathComponent)")
            return
        }
        imageView.image = image
    }

    /// Clear the displayed screenshot.
    func clearScreenshot() {
        imageView.image = nil
    }
}
