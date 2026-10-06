// Discovers routes from a Next.js Pages Router project by scanning pages/ or src/pages/
// for .tsx/.jsx/.ts/.js files. Skips _app, _document, _error, api/, and error pages.

import Foundation

struct NextPagesRouterAdapter: RouteAdapter {

    let name = "Next.js Pages Router"

    private let extensions: Set<String> = ["tsx", "jsx", "ts", "js"]
    private let skipStems: Set<String> = ["_app", "_document", "_error", "404", "500"]
    private let skipDirs: Set<String> = ["api", "node_modules", ".next"]

    func detect(projectDir: URL) -> URL? {
        for sub in ["pages", "src/pages"] {
            let dir = projectDir.appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: dir.path),
               hasJSFiles(in: dir) {
                return dir
            }
        }
        return nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var routes: [DiscoveredRoute] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension
            guard extensions.contains(ext) else { continue }

            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            if skipDirs.contains(parent) { enumerator.skipDescendants(); continue }

            let stem = fileURL.deletingPathExtension().lastPathComponent
            if skipStems.contains(stem) { continue }

            let relative = fileURL.path.replacingOccurrences(of: rootDir.path, with: "")
            if let route = convertRoute(filePath: relative) {
                routes.append(route)
            }
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) Next.js Pages routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasJSFiles(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            let ext = url.pathExtension
            // Must be JS/TS files but NOT .vue or .astro (those belong to Nuxt/Astro)
            if extensions.contains(ext) { return true }
        }
        return false
    }

    private func convertRoute(filePath: String) -> DiscoveredRoute? {
        var path = filePath

        // Strip extension
        for ext in extensions {
            if path.hasSuffix(".\(ext)") { path = String(path.dropLast(ext.count + 1)); break }
        }

        // index → parent path
        if path.hasSuffix("/index") { path = String(path.dropLast(6)) }

        path = RoutePathHelpers.normalizePath(path)
        let urlPath = RoutePathHelpers.replaceBracketDynamicSegments(path)
        return DiscoveredRoute(label: path, urlPath: urlPath)
    }
}
