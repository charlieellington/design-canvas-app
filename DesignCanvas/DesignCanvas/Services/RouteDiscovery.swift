// Coordinator that discovers routes from a project directory by trying multiple framework
// adapters in priority order. Supports Next.js (App + Pages Router), TanStack Router,
// Remix, SvelteKit, Nuxt, and Astro.

import Foundation

struct DiscoveredRoute {
    /// Display label — keeps dynamic segments like /blog/[slug] or /clients/$clientId
    let label: String
    /// URL-safe path — dynamic segments replaced with mock values like /blog/mock-slug
    let urlPath: String
}

/// Conforming types detect a specific framework in a project directory and return its routes.
protocol RouteAdapter {
    var name: String { get }
    /// Check whether this adapter applies. Returns the root directory to scan, or nil.
    func detect(projectDir: URL) -> URL?
    /// Discover routes from the detected root directory.
    func discoverRoutes(in rootDir: URL) -> [DiscoveredRoute]
}

@MainActor
class RouteDiscovery {

    /// Most recently discovered routes — used by CommandPaletteState to show available routes.
    private(set) var lastDiscovered: [DiscoveredRoute] = []

    /// Clear cached discovery results (e.g. when entering demo mode).
    func clearDiscovered() { lastDiscovered = [] }

    /// Adapters tried in priority order. Detection order matters for disambiguation:
    /// - Next.js App Router before Pages Router (App Router takes precedence)
    /// - SvelteKit before TanStack (both use src/routes/, disambiguated by file extension)
    /// - Next.js Pages before Nuxt (both use pages/, disambiguated by .vue vs .tsx)
    /// - Astro last (src/pages/ with .astro files is unambiguous)
    private let adapters: [RouteAdapter] = [
        NextAppRouterAdapter(),
        SvelteKitAdapter(),
        TanStackRouterAdapter(),
        RemixRouterAdapter(),
        NextPagesRouterAdapter(),
        NuxtAdapter(),
        AstroAdapter(),
    ]

    /// Discover all page routes in a project. Tries each adapter in priority order,
    /// returning the first non-empty result.
    func discoverRoutes(projectDir: URL) -> [DiscoveredRoute] {
        for adapter in adapters {
            if let rootDir = adapter.detect(projectDir: projectDir) {
                let routes = adapter.discoverRoutes(in: rootDir)
                if !routes.isEmpty {
                    lastDiscovered = routes
                    CrashReporter.shared.breadcrumb(category: "discovery", action: "discover", message: "\(routes.count) routes found")
                    return routes
                }
            }
        }
        print("[RouteDiscovery] No supported router structure found in \(projectDir.path)")
        return []
    }
}
