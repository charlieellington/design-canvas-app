// Self-healing path resolver for markdown frames. When a .md file moves within
// the watched project root, FSEvents emits both the old and new path in one
// debounced burst (FileWatcher.swift:194). The reload side then notices the old
// path is gone and would normally surface fileUnreadable to the user.
//
// This service short-circuits that: it walks the project for a file with the
// same basename, disambiguates by cached SHA256 when there are multiple, and
// hands back a new path so the model can be rewired without UI flicker.
//
// Out of scope: moves outside the project root (FSEvents doesn't see them) and
// hash-cache persistence across app restarts. After relaunch, single-basename
// heal still works; ambiguous cases stay broken until the user re-renders the
// frame (which seeds a fresh hash).

import Foundation
import CryptoKit

@MainActor
final class MarkdownPathHealer {

    /// Frame id → hex SHA256 of last-known content. Seeded after each successful render.
    private var hashByFrameId: [UUID: String] = [:]

    /// Mirrors MarkdownRenderer.maxFileSize — refuse to hash a file we'd refuse to render.
    private static let maxHashableBytes = MarkdownRenderer.maxFileSize

    struct MissingFrame: Sendable {
        let id: UUID
        let filePath: String
    }

    struct Resolution: Sendable {
        let frameId: UUID
        let oldPath: String
        let newPath: String
        /// True when there were multiple basename candidates and SHA256 picked the winner.
        let usedHash: Bool
    }

    // MARK: - Cache management

    /// Compute and cache a SHA256 of the file's contents. Silently no-ops on read failure
    /// or oversize files. Reads happen on a utility-priority detached task to keep the
    /// main thread responsive when many frames render in a burst.
    func recordHash(frameId: UUID, filePath: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let hex = Self.sha256Hex(filePath: filePath) else { return }
            await self?.storeHash(frameId: frameId, hex: hex)
        }
    }

    private func storeHash(frameId: UUID, hex: String) {
        hashByFrameId[frameId] = hex
    }

    /// Drop a frame's cached hash — call from CanvasManager.removeDocument.
    func forget(frameId: UUID) {
        hashByFrameId.removeValue(forKey: frameId)
    }

    /// Drop everything — call when switching projects so cross-project basename collisions
    /// can't accidentally satisfy a hash lookup.
    func reset() {
        hashByFrameId.removeAll()
    }

    // MARK: - Heal

    /// For each frame whose path no longer resolves on disk, search `projectDir` for a
    /// same-basename replacement. Returns the resolutions to apply; callers mutate the
    /// model and persist. The project walk and any candidate SHAs run off the main actor.
    func heal(missingFrames: [MissingFrame], projectDir: String) async -> [Resolution] {
        guard !missingFrames.isEmpty else { return [] }

        let cacheSnapshot = hashByFrameId
        return await Task.detached(priority: .utility) {
            Self.resolveOffMain(
                missingFrames: missingFrames,
                projectDir: projectDir,
                hashByFrameId: cacheSnapshot
            )
        }.value
    }

    nonisolated private static func resolveOffMain(
        missingFrames: [MissingFrame],
        projectDir: String,
        hashByFrameId: [UUID: String]
    ) -> [Resolution] {
        let allMarkdown = WorkspaceFileIndex.enumerate(
            projectDir: projectDir,
            extensions: ["md", "markdown"]
        )
        let byBasename = Dictionary(grouping: allMarkdown) { $0.filename }

        var resolutions: [Resolution] = []
        // Cache candidate hashes within this burst — two frames whose old basenames
        // collide in the same heal call won't re-read the same file twice.
        var hashCache: [String: String] = [:]

        for frame in missingFrames {
            let basename = (frame.filePath as NSString).lastPathComponent
            guard let candidates = byBasename[basename], !candidates.isEmpty else { continue }

            if candidates.count == 1 {
                resolutions.append(Resolution(
                    frameId: frame.id,
                    oldPath: frame.filePath,
                    newPath: candidates[0].absolutePath,
                    usedHash: false
                ))
                continue
            }

            guard let cachedHex = hashByFrameId[frame.id] else {
                // Ambiguous and no hash to break the tie — leave broken.
                continue
            }

            var matched: WorkspaceFileIndex.IndexedFile?
            for candidate in candidates {
                let hex = hashCache[candidate.absolutePath] ?? sha256Hex(filePath: candidate.absolutePath)
                if let hex { hashCache[candidate.absolutePath] = hex }
                if hex == cachedHex {
                    if matched != nil {
                        // Two candidates with identical content — refuse rather than guess.
                        matched = nil
                        break
                    }
                    matched = candidate
                }
            }
            guard let pick = matched else { continue }
            resolutions.append(Resolution(
                frameId: frame.id,
                oldPath: frame.filePath,
                newPath: pick.absolutePath,
                usedHash: true
            ))
        }
        return resolutions
    }

    // MARK: - SHA256

    /// Hex SHA256 of the file's contents, or nil if unreadable / oversize.
    nonisolated static func sha256Hex(filePath: String) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        if let size = attrs?[.size] as? Int, size > maxHashableBytes { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
