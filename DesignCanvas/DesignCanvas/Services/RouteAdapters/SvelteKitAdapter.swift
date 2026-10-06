// Discovers routes from a SvelteKit project by scanning src/routes/ for +page.svelte files.
// Handles route groups, dynamic [param] segments, and directory-based routing.

import Foundation

struct SvelteKitAdapter: RouteAdapter {

    let name = "SvelteKit"

    func detect(projectDir: URL) -> URL? {
        let dir = projectDir.appendingPathComponent("src/routes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return hasSveltePages(in: dir) ? dir : nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var routes: [DiscoveredRoute] = []

        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            guard fileName == "+page.svelte" else { continue }

            let relative = fileURL.deletingLastPathComponent().path
                .replacingOccurrences(of: rootDir.path, with: "")

            var path = RoutePathHelpers.stripRouteGroups(relative)
            path = RoutePathHelpers.normalizePath(path)
            let urlPath = RoutePathHelpers.replaceBracketDynamicSegments(path)
            routes.append(DiscoveredRoute(label: path, urlPath: urlPath))
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) SvelteKit routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasSveltePages(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "+page.svelte" { return true }
        }
        return false
    }
}
