// Stage 14.5a — content-version-keyed screenshot cache. Memory + disk tiers.
// Key shape (cross-stage §3): `(clientFrameId, viewport, backingScale,
// captureDelayMs, contentVersion)`. The same routePath served by two distinct
// frames lives at two distinct cache slots; raising the delay never reads
// the stale 0-ms entry.
//
// Disk path: `~/Library/Caches/DesignCanvas/screenshots/{sha256(cacheKey)}.jpg`
// — hashed so no raw URL strings or content fingerprints sit in the path.

import AppKit
import CryptoKit
import Foundation

@MainActor
final class ScreenshotCache {

    static let shared = ScreenshotCache()

    /// Composite cache key — every dimension that can change the rendered bitmap.
    struct Key: Hashable, Sendable {
        let clientFrameId: UUID
        let viewportW: Int
        let viewportH: Int
        let backingScale: Double
        let captureDelayMs: Int
        let contentVersion: Int

        /// Canonical string form fed into sha256. Stable across launches.
        var canonical: String {
            "\(clientFrameId.uuidString)|\(viewportW)x\(viewportH)|scale=\(backingScale)|delay=\(captureDelayMs)|cv=\(contentVersion)"
        }

        /// sha256 hex digest. Used as both the in-memory lookup token and the
        /// disk filename (NEVER store raw routePath in the path).
        var digest: String {
            let bytes = Data(canonical.utf8)
            let hash = SHA256.hash(data: bytes)
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Cache entry — image + canonical key + capture timestamp + contentVersion at capture time.
    struct Entry {
        let image: NSImage
        let key: Key
        let capturedAt: Date
        let fileURL: URL
    }

    /// In-memory LRU. Bounded by `maxMemoryEntries` — eviction is rough; the
    /// disk tier is the durable source. Bounded so a 100-route share doesn't
    /// pin 100 full-res NSImage in RAM after the session moves on.
    private static let maxMemoryEntries = 64

    private var memory: [String: Entry] = [:]
    private var accessOrder: [String] = []

    /// Caches directory for the screenshot tier.
    private static var screenshotDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(BuildPolicy.dataDirectoryName)/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: - Get

    /// Look up by full key. Returns nil on miss. Touches LRU order on hit.
    func get(_ key: Key) -> Entry? {
        if let hit = memory[key.digest] {
            bumpLRU(key.digest)
            return hit
        }
        let url = Self.screenshotDir.appendingPathComponent("\(key.digest).jpg")
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Disk hit — pull into memory tier with the original mtime as capturedAt
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let entry = Entry(image: image, key: key, capturedAt: mtime, fileURL: url)
        store(entry)
        return entry
    }

    /// Convenience helper: build the key + lookup in one call.
    func get(
        clientFrameId: UUID,
        viewport: CGSize,
        backingScale: CGFloat,
        captureDelayMs: Int,
        contentVersion: Int,
    ) -> Entry? {
        get(Key(
            clientFrameId: clientFrameId,
            viewportW: Int(viewport.width),
            viewportH: Int(viewport.height),
            backingScale: Double(backingScale),
            captureDelayMs: captureDelayMs,
            contentVersion: contentVersion,
        ))
    }

    // MARK: - Set

    /// Persist an image to disk + insert into memory tier. Returns the disk
    /// URL. JPEG-encodes at q=0.85 (Stage 13 contract for blob payload).
    @discardableResult
    func set(image: NSImage, for key: Key, capturedAt: Date = Date()) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        let url = Self.screenshotDir.appendingPathComponent("\(key.digest).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            print("[ScreenshotCache] write failed: \(error.localizedDescription)")
            return nil
        }
        let entry = Entry(image: image, key: key, capturedAt: capturedAt, fileURL: url)
        store(entry)
        return url
    }

    // MARK: - Invalidate

    /// Drop every cache entry for a `clientFrameId`. Called when the user
    /// removes a route or when contentVersion is bumped enough times that
    /// keeping stale entries on disk wastes space (the keyed lookup never
    /// reads stale data on its own — this is hygiene, not correctness).
    func invalidate(clientFrameId: UUID) {
        let prefix = clientFrameId.uuidString + "|"
        let stale = memory.values.filter { $0.key.canonical.hasPrefix(prefix) }
        for entry in stale {
            memory.removeValue(forKey: entry.key.digest)
            accessOrder.removeAll { $0 == entry.key.digest }
            try? FileManager.default.removeItem(at: entry.fileURL)
        }
    }

    // MARK: - LRU helpers

    private func store(_ entry: Entry) {
        let d = entry.key.digest
        memory[d] = entry
        bumpLRU(d)
        while memory.count > Self.maxMemoryEntries, let evict = accessOrder.first {
            memory.removeValue(forKey: evict)
            accessOrder.removeFirst()
        }
    }

    private func bumpLRU(_ digest: String) {
        accessOrder.removeAll { $0 == digest }
        accessOrder.append(digest)
    }
}
