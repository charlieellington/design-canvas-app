// Per-canvas record of a dev server that one or more routes are plugged into.
// Decoupled from DevServerManager — that owns spawn / probe / health of the
// PRIMARY server backing the document. Bindings persist; runtime is transient.
//
// origin is a full URL (http://localhost:3000) so we don't bake in localhost/http
// in persistence. status reflects last-known reachability — toggled by the
// registry's probe pass on app launch and on each scan cycle.

import Foundation

struct ServerBinding: Identifiable, Codable, Hashable {
    let id: UUID
    var origin: URL
    var displayName: String
    var projectDir: String?
    var packageName: String?
    var gitRemote: String?           // normalised host/path/repo, matches SessionPersistence's shape
    var lastSeenAt: Date
    var status: Status

    enum Status: String, Codable {
        case connected      // last probe responded
        case stale          // last probe failed, but we haven't given up
        case offline        // user dismissed the rebind toast / explicitly marked offline
    }

    /// Convenience: port from origin, when the URL is a standard localhost:<port> shape.
    var port: Int? { origin.port }

    /// Best-effort match against a runtime DetectedServer for rebind heuristics.
    /// Returns the strongest confidence tier that matches.
    enum MatchConfidence: Int, Comparable {
        case none, weak, medium, strong
        static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    func match(against detected: DetectedServer) -> MatchConfidence {
        // Strong: realpath equality on projectDir.
        if let dir = projectDir, let other = detected.projectDir,
           (dir as NSString).resolvingSymlinksInPath == (other as NSString).resolvingSymlinksInPath {
            return .strong
        }
        // Medium: detectedServer's project name matches our displayName (resolved from package.json
        // / lsof at bind time). Conductor worktrees share name + remote, so name alone is medium
        // unless caller has already established uniqueness on both sides.
        if displayName.lowercased() == detected.projectName.lowercased(), !displayName.isEmpty {
            return .medium
        }
        // Weak: nothing matches — caller can still surface as a manual option in the popover.
        return .none
    }
}
