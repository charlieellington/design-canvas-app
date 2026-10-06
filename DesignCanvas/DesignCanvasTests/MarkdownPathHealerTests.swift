// Tests for MarkdownPathHealer — single-candidate heal, hash disambiguation,
// no-candidate / no-hash failure modes, and cache lifecycle.

import XCTest
@testable import DesignCanvas

@MainActor
final class MarkdownPathHealerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("MarkdownPathHealerTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolved = (dir.path as NSString).resolvingSymlinksInPath
        tempRoot = URL(fileURLWithPath: resolved)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, contents: String) throws -> String {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - Heal

    func testSingleBasenameMatchHealsWithoutHash() async throws {
        let healer = MarkdownPathHealer()

        // File originally lived at docs/handover.md, has been moved to archive/handover.md.
        // The heal call only sees the new location.
        _ = try write("archive/handover.md", contents: "# Handover")

        let frameId = UUID()
        let oldPath = tempRoot.appendingPathComponent("docs/handover.md").path

        let resolutions = await healer.heal(
            missingFrames: [.init(id: frameId, filePath: oldPath)],
            projectDir: tempRoot.path
        )

        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].frameId, frameId)
        XCTAssertEqual(resolutions[0].oldPath, oldPath)
        XCTAssertTrue(resolutions[0].newPath.hasSuffix("/archive/handover.md"))
        XCTAssertFalse(resolutions[0].usedHash)
    }

    func testMultipleBasenamesUseHashToDisambiguate() async throws {
        let healer = MarkdownPathHealer()

        let aPath = try write("a/notes.md", contents: "alpha content")
        _ = try write("b/notes.md", contents: "beta content")

        let frameId = UUID()
        // Cache the hash of the original (alpha) before the move.
        await waitForHashSeed { healer.recordHash(frameId: frameId, filePath: aPath) }

        // Simulate the move: aPath disappears, content reappears at a/elsewhere/notes.md.
        try FileManager.default.removeItem(atPath: aPath)
        _ = try write("a/elsewhere/notes.md", contents: "alpha content")

        let resolutions = await healer.heal(
            missingFrames: [.init(id: frameId, filePath: aPath)],
            projectDir: tempRoot.path
        )

        XCTAssertEqual(resolutions.count, 1)
        XCTAssertTrue(resolutions[0].newPath.hasSuffix("/a/elsewhere/notes.md"))
        XCTAssertTrue(resolutions[0].usedHash)
    }

    func testMultipleBasenamesWithoutCachedHashLeavesUnresolved() async throws {
        let healer = MarkdownPathHealer()

        _ = try write("a/notes.md", contents: "alpha")
        _ = try write("b/notes.md", contents: "beta")

        let frameId = UUID()
        let oldPath = tempRoot.appendingPathComponent("c/notes.md").path

        let resolutions = await healer.heal(
            missingFrames: [.init(id: frameId, filePath: oldPath)],
            projectDir: tempRoot.path
        )

        XCTAssertTrue(resolutions.isEmpty, "ambiguity without a hash should not heal")
    }

    func testNoBasenameMatchLeavesUnresolved() async throws {
        let healer = MarkdownPathHealer()

        _ = try write("docs/other.md", contents: "irrelevant")

        let frameId = UUID()
        let oldPath = tempRoot.appendingPathComponent("docs/handover.md").path

        let resolutions = await healer.heal(
            missingFrames: [.init(id: frameId, filePath: oldPath)],
            projectDir: tempRoot.path
        )

        XCTAssertTrue(resolutions.isEmpty)
    }

    func testForgetDropsHashEntry() async throws {
        let healer = MarkdownPathHealer()

        let aPath = try write("a/notes.md", contents: "alpha content")
        _ = try write("b/notes.md", contents: "beta content")

        let frameId = UUID()
        await waitForHashSeed { healer.recordHash(frameId: frameId, filePath: aPath) }
        healer.forget(frameId: frameId)

        try FileManager.default.removeItem(atPath: aPath)
        _ = try write("a/elsewhere/notes.md", contents: "alpha content")

        let resolutions = await healer.heal(
            missingFrames: [.init(id: frameId, filePath: aPath)],
            projectDir: tempRoot.path
        )

        XCTAssertTrue(resolutions.isEmpty, "forget() should erase the hash so ambiguity stays unresolved")
    }

    // MARK: - SHA256

    func testSha256HexIsStable() throws {
        let path = try write("doc.md", contents: "stable content")
        let a = MarkdownPathHealer.sha256Hex(filePath: path)
        let b = MarkdownPathHealer.sha256Hex(filePath: path)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.count, 64)  // 32 bytes hex-encoded
    }

    func testSha256HexNilForMissingFile() {
        let path = tempRoot.appendingPathComponent("does-not-exist.md").path
        XCTAssertNil(MarkdownPathHealer.sha256Hex(filePath: path))
    }

    // MARK: - Helpers

    /// recordHash dispatches to a detached task; spin briefly so the cache is populated
    /// before the test continues. 200ms is plenty for a small file SHA on local disk.
    private func waitForHashSeed(_ block: () -> Void) async {
        block()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
