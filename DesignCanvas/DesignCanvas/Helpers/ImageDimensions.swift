// Reads image pixel dimensions from the file header without decoding the full bitmap.
// Used by CanvasManager.addImage to size newly-added image frames to their natural aspect
// ratio, so portrait photos don't get letterboxed inside a 600×400 landscape frame.

import AppKit
import ImageIO

enum ImageDimensions {
    static let defaultLongestSide: CGFloat = 600

    /// Probe image pixel dimensions without decoding. Respects EXIF orientation
    /// (iPhone photos often store rotated pixels with orientation=6/8).
    /// Returns nil for formats CGImageSource can't introspect (SVG, malformed files).
    static func pixelSize(ofFileAt path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swap = orientation >= 5 && orientation <= 8
        return swap ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Fit a pixel size into a box whose longest side is `longestSide`, preserving aspect ratio.
    static func fittedSize(for pixelSize: CGSize, longestSide: CGFloat = defaultLongestSide) -> CGSize {
        let scale = longestSide / max(pixelSize.width, pixelSize.height)
        return CGSize(width: round(pixelSize.width * scale),
                      height: round(pixelSize.height * scale))
    }
}
