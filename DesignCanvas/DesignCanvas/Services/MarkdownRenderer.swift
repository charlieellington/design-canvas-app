// Renders a .md or .html file for display in a WKWebView via loadHTMLString(_:baseURL:).
// The file's parent directory becomes the baseURL so `![](./fig.png)` resolves natively.
// Markdown is inlined into a <script type="text/markdown"> element (non-executing) and parsed
// client-side by marked + highlighted by highlight.js — both bundled in MarkdownTemplate.html.
// HTML files are loaded as-is, bypassing the template (the file is already a complete document).

import Foundation

enum MarkdownRenderer {

    enum RenderError: Error {
        case templateMissing
        case fileUnreadable(path: String)
        case fileTooLarge(bytes: Int)
    }

    /// Hard cap on markdown file size. 5 MB is ~500 pages of prose — beyond this, refuse rather
    /// than hitch the main thread on String(contentsOf:).
    static let maxFileSize = 5 * 1024 * 1024

    /// Returns (html, baseURL) ready to hand to WKWebView.loadHTMLString(_:baseURL:).
    static func render(filePath: String) throws -> (html: String, baseURL: URL) {
        let fileURL = URL(fileURLWithPath: filePath)
        let ext = fileURL.pathExtension.lowercased()

        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        if let size = attrs?[.size] as? Int, size > maxFileSize {
            throw RenderError.fileTooLarge(bytes: size)
        }

        let source: String
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw RenderError.fileUnreadable(path: filePath)
        }

        // baseURL is the file's parent directory. WKWebView resolves relative
        // <img src="./fig.png"> against this via file:// — no custom scheme handler needed.
        let baseURL = fileURL.deletingLastPathComponent()

        // HTML files load as-is. Same baseURL trick so relative assets resolve.
        if ext == "html" || ext == "htm" {
            return (source, baseURL)
        }

        // Markdown path: HTML-escape for safety inside <script type="text/markdown">. The
        // script type is non-executing so arbitrary text is safe, but </script> must not
        // appear or the parser closes the element prematurely.
        let escaped = source.replacingOccurrences(of: "</script>", with: "<\\/script>")
        let html = try template().replacingOccurrences(of: "{{MARKDOWN_ESCAPED}}", with: escaped)
        return (html, baseURL)
    }

    // MARK: - Template loading (cached on success only)

    // Cache only successful loads. A `static let` would freeze a `nil` result for the lifetime
    // of the process, which bites us if the first lookup races with Xcode rewriting the bundle
    // during an incremental rebuild.
    private static var templateCache: String?
    private static let templateCacheLock = NSLock()

    private static func template() throws -> String {
        templateCacheLock.lock()
        defer { templateCacheLock.unlock() }

        if let cached = templateCache { return cached }

        guard let url = Bundle.main.url(forResource: "MarkdownTemplate",
                                        withExtension: "html",
                                        subdirectory: "MarkdownRenderer") ??
                       Bundle.main.url(forResource: "MarkdownTemplate", withExtension: "html"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw RenderError.templateMissing
        }
        templateCache = contents
        return contents
    }
}
