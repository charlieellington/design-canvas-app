// Tests for WorkspaceFileIndex — ignore rules, relative paths, empty case.

import XCTest
@testable import DesignCanvas

final class WorkspaceFileIndexTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("WorkspaceFileIndexTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve symlinks (/var → /private/var) so tempRoot.path matches what
        // WorkspaceFileIndex returns. NSString's resolver handles parent symlinks
        // reliably; URL.resolvingSymlinksInPath() sometimes does not.
        let resolved = (dir.path as NSString).resolvingSymlinksInPath
        tempRoot = URL(fileURLWithPath: resolved)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, contents: String = "") throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    func testFindsMarkdownAndSkipsIgnoredDirs() throws {
        try write("README.md", contents: "# root")
        try write("docs/a.md", contents: "# a")
        try write("node_modules/pkg/readme.md", contents: "should be skipped")
        try write(".git/HEAD", contents: "should be skipped")
        try write(".next/cache/manifest.md", contents: "should be skipped")
        try write(".hidden.md", contents: "dotfile — should be skipped")
        try write("docs/image.png", contents: "wrong extension")

        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )

        let relPaths = Set(files.map(\.relativePath))
        XCTAssertEqual(relPaths, ["README.md", "docs/a.md"])
    }

    func testReturnsAbsolutePaths() throws {
        try write("notes.md")
        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].absolutePath.hasSuffix("/notes.md"))
        XCTAssertTrue(files[0].absolutePath.hasPrefix(tempRoot.path))
    }

    func testRelativePathsUseForwardSlashAndSkipRoot() throws {
        try write("a/b/c/deep.md")
        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].relativePath, "a/b/c/deep.md")
        XCTAssertEqual(files[0].parentPathDisplay, "a/b/c/")
        XCTAssertEqual(files[0].filename, "deep.md")
    }

    func testRootLevelFileHasEmptyParentDisplay() throws {
        try write("top.md")
        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].parentPathDisplay, "")
    }

    func testEmptyDirectoryReturnsEmpty() {
        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files, [])
    }

    func testSkipsLockfilesAndSwapFiles() throws {
        try write("package-lock.json")
        try write(".DS_Store")
        try write("foo.md.swp")
        try write("real.md")

        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files.map(\.filename), ["real.md"])
    }

    func testSortsAlphabeticallyByFilename() throws {
        try write("charlie.md")
        try write("alice.md")
        try write("sub/bob.md")

        let files = WorkspaceFileIndex.enumerate(
            projectDir: tempRoot.path,
            extensions: ["md", "markdown"]
        )
        XCTAssertEqual(files.map(\.filename), ["alice.md", "bob.md", "charlie.md"])
    }
}
