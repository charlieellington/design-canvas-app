// Shared path manipulation helpers used by multiple route adapters.
// Handles dynamic segment replacement, route group stripping, and path normalization.

import Foundation

enum RoutePathHelpers {

    /// Replace bracket-style dynamic segments with mock values for URL construction.
    /// [slug] → mock-slug, [...catchAll] → mock-catch-all, [[...optional]] → mock-optional
    static func replaceBracketDynamicSegments(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        let replaced = segments.map { segment -> String in
            let s = String(segment)
            if s.hasPrefix("[[...") && s.hasSuffix("]]") {
                return "mock-\(s.dropFirst(5).dropLast(2))"
            }
            if s.hasPrefix("[...") && s.hasSuffix("]") {
                return "mock-\(s.dropFirst(4).dropLast(1))"
            }
            if s.hasPrefix("[") && s.hasSuffix("]") {
                return "mock-\(s.dropFirst(1).dropLast(1))"
            }
            return s
        }
        return replaced.isEmpty ? "/" : "/" + replaced.joined(separator: "/")
    }

    /// Replace a TanStack/Remix dollar-style dynamic segment: $param → mock-param, $ → mock-splat
    static func replaceDollarDynamicSegment(_ segment: String) -> String {
        if segment == "$" { return "mock-splat" }
        if segment.hasPrefix("$") { return "mock-\(segment.dropFirst())" }
        return segment
    }

    /// Remove route group segments like `(marketing)` from the path.
    /// Used by Next.js App Router and SvelteKit.
    static func stripRouteGroups(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        let filtered = segments.filter { !($0.hasPrefix("(") && $0.hasSuffix(")")) }
        return filtered.isEmpty ? "/" : "/" + filtered.joined(separator: "/")
    }

    /// Normalize a route path: ensure leading slash, remove trailing slash, collapse double slashes.
    static func normalizePath(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if !p.hasPrefix("/") { p = "/" + p }
        if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        if p.isEmpty { p = "/" }
        return p
    }
}
