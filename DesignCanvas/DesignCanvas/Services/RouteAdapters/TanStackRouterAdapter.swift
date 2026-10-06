// Discovers routes from a TanStack Router project using file-based routing in src/routes/.
// Handles flat files (dots as path separators), directory-based routes, and $param dynamic segments.

import Foundation

struct TanStackRouterAdapter: RouteAdapter {

    let name = "TanStack Router"

    private let extensions: Set<String> = ["tsx", "jsx", "ts", "js"]

    func detect(projectDir: URL) -> URL? {
        let dir = projectDir.appendingPathComponent("src/routes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        // Disambiguate from SvelteKit: must have .tsx/.jsx files and no +page.svelte
        return hasFiles(in: dir, withExtensions: extensions) ? dir : nil
    }

    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute] {
        let allFiles = collectFiles(in: rootDir)
        let stems = Set(allFiles.map { stem($0) })

        var routes: [DiscoveredRoute] = []
        for file in allFiles {
            let s = stem(file)
            if s == "__root" { continue }

            // Skip layout files: `foo.tsx` where `foo.index.tsx` or `foo.bar.tsx` children exist
            if !s.contains(".") && !s.hasPrefix("$") && s != "index" {
                if stems.contains(where: { $0.hasPrefix(s + ".") }) { continue }
            }

            if let route = convertRoute(stem: s) { routes.append(route) }
        }

        var seen = Set<String>()
        routes = routes.filter { seen.insert($0.label).inserted }.sorted { $0.label < $1.label }
        print("[RouteDiscovery] Found \(routes.count) TanStack routes in \(rootDir.path)")
        return routes
    }

    // MARK: - Private

    private func hasFiles(in directory: URL, withExtensions exts: Set<String>) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if exts.contains(url.pathExtension) { return true }
        }
        return false
    }

    private func collectFiles(in rootDir: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        for case let fileURL as URL in enumerator {
            guard extensions.contains(fileURL.pathExtension) else { continue }
            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            if parent == "node_modules" || parent == ".tanstack" {
                enumerator.skipDescendants(); continue
            }
            files.append(fileURL.path.replacingOccurrences(of: rootDir.path, with: ""))
        }
        return files
    }

    /// Extract file stem without extension. e.g. "/clients.$clientId.tsx" → "clients.$clientId"
    private func stem(_ relativePath: String) -> String {
        var s = relativePath
        if s.hasPrefix("/") { s = String(s.dropFirst()) }
        if let dot = s.lastIndex(of: ".") {
            let ext = String(s[s.index(after: dot)...])
            if extensions.contains(ext) { s = String(s[..<dot]) }
        }
        return s
    }

    private func convertRoute(stem: String) -> DiscoveredRoute? {
        if stem == "index" { return DiscoveredRoute(label: "/", urlPath: "/") }

        var segments: [String] = []
        for dirPart in stem.split(separator: "/", omittingEmptySubsequences: true) {
            segments.append(contentsOf: dirPart.split(separator: ".", omittingEmptySubsequences: true).map(String.init))
        }
        if segments.last == "index" { segments.removeLast() }
        guard !segments.isEmpty else { return DiscoveredRoute(label: "/", urlPath: "/") }

        let label = "/" + segments.joined(separator: "/")
        let urlPath = "/" + segments.map { RoutePathHelpers.replaceDollarDynamicSegment($0) }.joined(separator: "/")
        return DiscoveredRoute(label: label, urlPath: urlPath)
    }
}
