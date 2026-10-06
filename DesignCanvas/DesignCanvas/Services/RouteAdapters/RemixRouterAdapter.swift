// Discovers routes from a Remix / React Router v7 project by scanning app/routes/.
// Uses flat-file convention (dots as path separators), $param dynamic segments,
// and _index/_layout underscore prefixes.

import Foundation

struct RemixRouterAdapter: RouteAdapter {

    let name = "Remix"

    private let extensions: Set<String> = ["tsx", "jsx", "ts", "js"]

    func detect(projectDir: URL) -> URL? {
        let dir = projectDir.appendingPathComponent("app/routes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return hasFiles(in: dir) ? dir : nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var routes: [DiscoveredRoute] = []

        for case let fileURL as URL in enumerator {
            guard extensions.contains(fileURL.pathExtension) else { continue }
            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            if parent == "node_modules" { enumerator.skipDescendants(); continue }

            let relative = fileURL.path.replacingOccurrences(of: rootDir.path, with: "")
            if let route = convertRoute(filePath: relative) {
                routes.append(route)
            }
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) Remix routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasFiles(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if extensions.contains(url.pathExtension) { return true }
        }
        return false
    }

    private func convertRoute(filePath: String) -> DiscoveredRoute? {
        var stem = filePath
        if stem.hasPrefix("/") { stem = String(stem.dropFirst()) }
        // Strip extension
        for ext in extensions {
            if stem.hasSuffix(".\(ext)") { stem = String(stem.dropLast(ext.count + 1)); break }
        }

        // Skip layout files
        let baseName = stem.split(separator: "/").last.map(String.init) ?? stem
        if baseName.hasSuffix("_layout") || baseName == "_layout" { return nil }

        // Split by "/" (directory), then by "." (flat segments)
        var segments: [String] = []
        for dirPart in stem.split(separator: "/", omittingEmptySubsequences: true) {
            segments.append(contentsOf: dirPart.split(separator: ".", omittingEmptySubsequences: true).map(String.init))
        }

        // Remove _index → maps to parent path
        if segments.last == "_index" { segments.removeLast() }

        // Root index
        if segments.isEmpty { return DiscoveredRoute(label: "/", urlPath: "/") }

        // Strip leading underscores from pathless layout segments (e.g. _auth.login → /login)
        segments = segments.filter { !$0.hasPrefix("_") || $0.hasPrefix("$") }

        guard !segments.isEmpty else { return DiscoveredRoute(label: "/", urlPath: "/") }

        let label = "/" + segments.joined(separator: "/")
        let urlPath = "/" + segments.map { RoutePathHelpers.replaceDollarDynamicSegment($0) }.joined(separator: "/")
        return DiscoveredRoute(label: label, urlPath: urlPath)
    }
}
