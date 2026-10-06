// Tiered matcher for the "server moved ports" case.
//
// Strong (auto-toast eligible): realpath of projectDir matches a stale binding's
//   projectDir AND the new port is unique (exactly one new port in this scan window).
// Medium (auto-toast eligible): packageName / displayName match + exactly one
//   stale candidate AND exactly one matching new-runtime candidate.
// Weak (popover only, never toast): packageName match alone — Conductor worktree
//   case has identical names across worktrees and would false-positive constantly.
//
// The matcher reads `document.bindings` + `portScanner.detectedServers`. It does
// not mutate; the caller (DesignCanvasApp) applies the rebind by writing the
// new origin/port/status on the existing binding.

import Foundation

@MainActor
struct PortRebindMatcher {

    enum Confidence: Int, Comparable {
        case weak, medium, strong
        static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    struct Match {
        let binding: ServerBinding
        let newServer: DetectedServer
        let confidence: Confidence
    }

    /// Find candidate rebind matches. Caller filters by confidence — only strong/medium
    /// surface as toasts; weak surfaces in the pill popover as a manual option.
    static func scan(bindings: [ServerBinding], detected: [DetectedServer], boundPorts: Set<Int>) -> [Match] {
        // Stale bindings are eligible. .connected bindings don't need a rebind candidate.
        let staleBindings = bindings.filter { $0.status == .stale || $0.status == .offline }
        guard !staleBindings.isEmpty else { return [] }

        // Newly-detected ports that aren't already bound. These are the candidates.
        let candidates = detected.filter { !boundPorts.contains($0.port) }
        guard !candidates.isEmpty else { return [] }

        var matches: [Match] = []
        for binding in staleBindings {
            // Strong: realpath equality on projectDir.
            if let dir = binding.projectDir {
                let needle = (dir as NSString).resolvingSymlinksInPath
                if let server = candidates.first(where: {
                    guard let other = $0.projectDir else { return false }
                    return (other as NSString).resolvingSymlinksInPath == needle
                }) {
                    matches.append(Match(binding: binding, newServer: server, confidence: .strong))
                    continue
                }
            }

            // Medium: name equality + exactly one stale + exactly one new candidate sharing
            // the name. Conductor worktrees fail this because multiple stale bindings share
            // names — that path falls to .weak below.
            let nameKey = binding.displayName.lowercased()
            if !nameKey.isEmpty {
                let sameNameStale = staleBindings.filter { $0.displayName.lowercased() == nameKey }
                let sameNameCandidates = candidates.filter { $0.projectName.lowercased() == nameKey }
                if sameNameStale.count == 1, sameNameCandidates.count == 1 {
                    matches.append(Match(
                        binding: binding,
                        newServer: sameNameCandidates[0],
                        confidence: .medium
                    ))
                    continue
                }
                // Weak: anything looser. Surface only as a popover option.
                if let server = sameNameCandidates.first {
                    matches.append(Match(binding: binding, newServer: server, confidence: .weak))
                }
            }
        }
        return matches
    }
}
