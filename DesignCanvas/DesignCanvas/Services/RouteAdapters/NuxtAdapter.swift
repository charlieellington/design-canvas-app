// Discovers routes from a Nuxt project by scanning pages/ for .vue files.
// Handles directory-based routing and [param] dynamic segments.

import Foundation

struct NuxtAdapter: RouteAdapter {

    let name = "Nuxt"

    func detect(projectDir: URL) -> URL? {
        let dir = projectDir.appendingPathComponent("pages")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return hasVueFiles(in: dir) ? dir : nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var routes: [DiscoveredRoute] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "vue" else { continue }
            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            if parent == "node_modules" { enumerator.skipDescendants(); continue }

            let relative = fileURL.path.replacingOccurrences(of: rootDir.path, with: "")
            if let route = convertRoute(filePath: relative) {
                routes.append(route)
            }
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) Nuxt routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasVueFiles(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if url.pathExtension == "vue" { return true }
        }
        return false
    }

    private func convertRoute(filePath: String) -> DiscoveredRoute? {
        var path = filePath
        if path.hasSuffix(".vue") { path = String(path.dropLast(4)) }
        if path.hasSuffix("/index") { path = String(path.dropLast(6)) }
        path = RoutePathHelpers.normalizePath(path)
        let urlPath = RoutePathHelpers.replaceBracketDynamicSegments(path)
        return DiscoveredRoute(label: path, urlPath: urlPath)
    }
}
