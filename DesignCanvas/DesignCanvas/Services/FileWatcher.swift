// Watches a project directory for source file changes using macOS FSEvents.
// Filters noise (node_modules, .next, .git), debounces change bursts into a single
// callback, and distinguishes page file changes (for route discovery) from general
// source changes (for screenshot re-capture). Stage 9 implementation.

import Foundation

class FileWatcher {

    // MARK: - Callbacks (fire on main thread)

    /// Called when relevant source files change — trigger screenshot re-capture.
    var onSourceFilesChanged: (() -> Void)?

    /// Called when page files (page.tsx etc.) are added or deleted — trigger route discovery.
    var onPageFilesChanged: (() -> Void)?

    /// Called when .md or .markdown files change. Receives absolute paths so the callback
    /// can reload only the affected frame(s).
    var onDocumentFilesChanged: ((Set<String>) -> Void)?

    /// Called when image files change. Receives absolute paths.
    var onImageFilesChanged: ((Set<String>) -> Void)?

    // MARK: - State

    private var stream: FSEventStreamRef?
    private let watchPath: String
    private var debounceWork: DispatchWorkItem?
    private var pendingPageFileChange = false
    /// Paths (absolute) of markdown/image files touched since the last debounced fire.
    private var pendingDocumentPaths: Set<String> = []
    private var pendingImagePaths: Set<String> = []

    // MARK: - Filter constants

    private static let sourceExtensions: Set<String> = [
        "tsx", "jsx", "ts", "js", "css"
    ]
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "heic"]
    private static let relevantExtensions: Set<String> =
        sourceExtensions.union(markdownExtensions).union(imageExtensions)

    private static let pageFileNames: Set<String> = [
        "page.tsx", "page.jsx", "page.ts", "page.js"
    ]

    private static let ignoredPathComponents: Set<String> = [
        "node_modules", ".next", ".git"
    ]

    private static let ignoredFileNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".DS_Store"
    ]

    // MARK: - Init

    init(watchPath: String) {
        self.watchPath = watchPath
    }

    // MARK: - Start / Stop

    func start() {
        guard stream == nil else { return }

        let pathsToWatch = [watchPath as CFString] as CFArray

        // Pass self as unretained — safe because stop() invalidates the stream
        // before deallocation, so the callback can never fire on a dead object.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let newStream = FSEventStreamCreate(
            nil,
            FileWatcher.eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // 1-second built-in FSEvents coalescing latency
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            print("[FileWatcher] Failed to create FSEvent stream")
            return
        }

        self.stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
        print("[FileWatcher] Started watching: \(watchPath)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounceWork?.cancel()
        debounceWork = nil
        pendingPageFileChange = false
        print("[FileWatcher] Stopped")
    }

    // MARK: - FSEvents C callback

    /// Static C-compatible callback. Extracts the FileWatcher from the info pointer
    /// and forwards the event paths for filtering.
    private static let eventCallback: FSEventStreamCallback = {
        _, clientInfo, numEvents, eventPaths, _, _ in

        guard let clientInfo else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

        // kFSEventStreamCreateFlagUseCFTypes means eventPaths is a CFArray of CFString
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        var paths: [String] = []
        for i in 0..<numEvents {
            if let rawPtr = CFArrayGetValueAtIndex(cfArray, i) {
                let str = Unmanaged<CFString>.fromOpaque(rawPtr).takeUnretainedValue() as String
                paths.append(str)
            }
        }

        watcher.handleRawEvents(paths)
    }

    // MARK: - Event filtering and debouncing

    private func handleRawEvents(_ paths: [String]) {
        var hasSourceChanges = false
        var hasDocumentChanges = false
        var hasImageChanges = false

        for path in paths {
            guard isRelevant(path) else { continue }
            let ext = (path as NSString).pathExtension.lowercased()

            if Self.sourceExtensions.contains(ext) {
                hasSourceChanges = true
                let filename = (path as NSString).lastPathComponent
                if Self.pageFileNames.contains(filename) {
                    pendingPageFileChange = true
                }
            } else if Self.markdownExtensions.contains(ext) {
                hasDocumentChanges = true
                pendingDocumentPaths.insert(path)
            } else if Self.imageExtensions.contains(ext) {
                hasImageChanges = true
                pendingImagePaths.insert(path)
            }
        }

        guard hasSourceChanges || hasDocumentChanges || hasImageChanges else { return }

        // Debounce: batch events within 500ms into one callback
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            if !self.pendingDocumentPaths.isEmpty {
                let paths = self.pendingDocumentPaths
                self.pendingDocumentPaths.removeAll()
                CrashReporter.shared.breadcrumb(category: "filewatcher", action: "document_change",
                                                message: "\(paths.count) paths")
                self.onDocumentFilesChanged?(paths)
            }
            if !self.pendingImagePaths.isEmpty {
                let paths = self.pendingImagePaths
                self.pendingImagePaths.removeAll()
                CrashReporter.shared.breadcrumb(category: "filewatcher", action: "image_change",
                                                message: "\(paths.count) paths")
                self.onImageFilesChanged?(paths)
            }
            if self.pendingPageFileChange {
                self.pendingPageFileChange = false
                CrashReporter.shared.breadcrumb(category: "filewatcher", action: "page_change", message: "")
                self.onPageFilesChanged?()
            }
            // Only fire source-changed callback when source files (not md/images) changed —
            // markdown/image changes have their own dedicated callbacks with path sets.
            if hasSourceChanges {
                CrashReporter.shared.breadcrumb(category: "filewatcher", action: "source_change", message: "")
                self.onSourceFilesChanged?()
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Returns true if this path represents a source file change we care about.
    private func isRelevant(_ path: String) -> Bool {
        // Exclude noisy directories
        for component in Self.ignoredPathComponents {
            if path.contains("/\(component)/") { return false }
        }

        let filename = (path as NSString).lastPathComponent

        // Exclude specific files
        if Self.ignoredFileNames.contains(filename) { return false }
        if filename.hasSuffix(".swp") || filename.hasSuffix(".swo") { return false }
        if filename.hasPrefix(".") { return false }

        // Only relevant extensions
        let ext = (path as NSString).pathExtension
        return Self.relevantExtensions.contains(ext)
    }

    deinit {
        stop()
    }
}
