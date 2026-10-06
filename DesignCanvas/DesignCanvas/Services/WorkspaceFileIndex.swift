// Snapshot of files (by extension) under the watched project root. Fed to the
// command palette's markdown picker. Enumeration runs off the main actor; the
// observable state is @MainActor.

import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceFileIndex {

    struct IndexedFile: Hashable, Sendable {
        let absolutePath: String
        /// Path relative to the workspace root, forward-slash separated (e.g. "docs/architecture/overview.md").
        let relativePath: String

        var filename: String {
            (absolutePath as NSString).lastPathComponent
        }

        /// Parent directory with trailing slash, or empty string if the file is at the root.
        var parentPathDisplay: String {
            let parent = (relativePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? "" : parent + "/"
        }
    }

    private(set) var markdownFiles: [IndexedFile] = []
    private(set) var lastIndexedDir: String?
    private(set) var isIndexing: Bool = false

    // Mirrors FileWatcher.ignoredPathComponents (FileWatcher.swift:49-55).
    private static let ignoredComponents: Set<String> = [
        "node_modules", ".next", ".git"
    ]

    private static let ignoredFilenames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", ".DS_Store"
    ]

    // MARK: - Public API

    /// Walk the project directory for files matching any of the given extensions
    /// and publish the result to `markdownFiles`. No-op if already running.
    func refresh(projectDir: String, extensions: Set<String> = ["md", "markdown"]) async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        let files = await Task.detached(priority: .utility) {
            Self.enumerate(projectDir: projectDir, extensions: extensions)
        }.value

        markdownFiles = files
        lastIndexedDir = projectDir
    }

    /// Drop the cache so the next `refresh` re-walks the tree. Call when a
    /// FileWatcher.onDocumentFilesChanged callback fires.
    func invalidate() {
        markdownFiles = []
        lastIndexedDir = nil
    }

    // MARK: - Enumeration (nonisolated — runs off the main actor)

    nonisolated static func enumerate(projectDir: String, extensions: Set<String>) -> [IndexedFile] {
        // Resolve symlinks so /var/… and /private/var/… comparisons match. Without
        // this, enumerator URLs (which are symlink-resolved on macOS) would fail the
        // prefix check in `relativePath(for:relativeTo:)`.
        let resolvedRootPath = (projectDir as NSString).resolvingSymlinksInPath
        let root = URL(fileURLWithPath: resolvedRootPath)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [IndexedFile] = []

        for case let url as URL in enumerator {
            let name = url.lastPathComponent

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if Self.ignoredComponents.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if name.hasPrefix(".") { continue }
            if Self.ignoredFilenames.contains(name) { continue }
            if name.hasSuffix(".swp") || name.hasSuffix(".swo") { continue }

            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            let resolvedUrlPath = (url.path as NSString).resolvingSymlinksInPath
            let rel = Self.relativePath(for: resolvedUrlPath, relativeTo: resolvedRootPath)
            results.append(IndexedFile(absolutePath: resolvedUrlPath, relativePath: rel))
        }

        return results.sorted { lhs, rhs in
            let lf = lhs.filename.lowercased()
            let rf = rhs.filename.lowercased()
            if lf != rf { return lf < rf }
            return lhs.relativePath < rhs.relativePath
        }
    }

    nonisolated static func relativePath(for path: String, relativeTo root: String) -> String {
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootWithSlash) {
            return String(path.dropFirst(rootWithSlash.count))
        }
        return path
    }
}
