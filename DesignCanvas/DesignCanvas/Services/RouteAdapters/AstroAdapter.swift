// Discovers routes from an Astro project by scanning src/pages/ for .astro, .md, and .mdx files.
// Handles directory-based routing and [param] dynamic segments.

import Foundation

struct AstroAdapter: RouteAdapter {

    let name = "Astro"

    private let pageExtensions: Set<String> = ["astro", "md", "mdx"]

    func detect(projectDir: URL) -> URL? {
        let dir = projectDir.appendingPathComponent("src/pages")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return hasAstroFiles(in: dir) ? dir : nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var routes: [DiscoveredRoute] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension
            guard pageExtensions.contains(ext) else { continue }

            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            if parent == "node_modules" { enumerator.skipDescendants(); continue }

            // Skip Astro partials (underscore-prefixed files)
            let stem = fileURL.deletingPathExtension().lastPathComponent
            if stem.hasPrefix("_") { continue }

            let relative = fileURL.path.replacingOccurrences(of: rootDir.path, with: "")
            if let route = convertRoute(filePath: relative, ext: ext) {
                routes.append(route)
            }
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) Astro routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasAstroFiles(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if pageExtensions.contains(url.pathExtension) { return true }
        }
        return false
    }

    private func convertRoute(filePath: String, ext: String) -> DiscoveredRoute? {
        var path = filePath
        if path.hasSuffix(".\(ext)") { path = String(path.dropLast(ext.count + 1)) }
        if path.hasSuffix("/index") { path = String(path.dropLast(6)) }
        path = RoutePathHelpers.normalizePath(path)
        let urlPath = RoutePathHelpers.replaceBracketDynamicSegments(path)
        return DiscoveredRoute(label: path, urlPath: urlPath)
    }
}
