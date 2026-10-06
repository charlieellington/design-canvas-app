// Discovers routes from a Next.js App Router project by scanning for page.tsx files
// in app/ or src/app/ directories. Handles route groups, dynamic segments, and parallel routes.

import Foundation

struct NextAppRouterAdapter: RouteAdapter {

    let name = "Next.js App Router"

    private let pageFileNames: Set<String> = ["page.tsx", "page.jsx", "page.ts", "page.js"]
    private let skipDirectories: Set<String> = ["api", "node_modules", ".next"]

    func detect(projectDir: URL) -> URL? {
        for sub in ["app", "src/app"] {
            let dir = projectDir.appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: dir.path),
               hasPageFiles(in: dir) {
                return dir
            }
        }
        return nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        let pagePaths = findPageFiles(in: rootDir)
        let routes = pagePaths.map { convertRoute(filePath: $0) }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) Next.js App Router routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasPageFiles(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let fileURL as URL in enumerator {
            if pageFileNames.contains(fileURL.lastPathComponent) { return true }
        }
        return false
    }

    private func findPageFiles(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            let parentDir = fileURL.deletingLastPathComponent().lastPathComponent
            if parentDir.hasPrefix("_") || parentDir.hasPrefix("@")
                || parentDir.hasPrefix("(.)") || parentDir.hasPrefix("(..)") {
                enumerator.skipDescendants(); continue
            }
            if skipDirectories.contains(parentDir) {
                enumerator.skipDescendants(); continue
            }
            if pageFileNames.contains(fileURL.lastPathComponent) {
                results.append(fileURL.path.replacingOccurrences(of: directory.path, with: ""))
            }
        }
        return results
    }

    private func convertRoute(filePath: String) -> DiscoveredRoute {
        var path = filePath
        for name in pageFileNames {
            if path.hasSuffix("/\(name)") { path = String(path.dropLast(name.count + 1)); break }
        }
        path = RoutePathHelpers.stripRouteGroups(path)
        path = RoutePathHelpers.normalizePath(path)
        let urlPath = RoutePathHelpers.replaceBracketDynamicSegments(path)
        return DiscoveredRoute(label: path, urlPath: urlPath)
    }
}
