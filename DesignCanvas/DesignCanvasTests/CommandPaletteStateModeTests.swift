// Tests for CommandPaletteState mode transitions — root ↔ markdownPicker ↔
// imagePicker — and reset behaviour on open/openForAssign/close.

import XCTest
@testable import DesignCanvas

@MainActor
final class CommandPaletteStateModeTests: XCTestCase {

    func testOpenResetsModeToRoot() {
        let state = CommandPaletteState()
        state.mode = .markdownPicker
        state.searchText = "stale"

        state.open()

        XCTAssertEqual(state.mode, .root)
        XCTAssertEqual(state.searchText, "")
        XCTAssertTrue(state.isOpen)
    }

    func testOpenForAssignResetsModeToRoot() {
        let state = CommandPaletteState()
        state.mode = .imagePicker

        state.openForAssign(frameId: UUID())

        XCTAssertEqual(state.mode, .root)
        XCTAssertTrue(state.isAssignMode)
    }

    func testEnterMarkdownPickerClearsSearch() {
        let state = CommandPaletteState()
        state.searchText = "leftover"

        state.enterMarkdownPicker()

        XCTAssertEqual(state.mode, .markdownPicker)
        XCTAssertEqual(state.searchText, "")
    }

    func testEnterImagePickerClearsSearch() {
        let state = CommandPaletteState()
        state.searchText = "leftover"

        state.enterImagePicker()

        XCTAssertEqual(state.mode, .imagePicker)
        XCTAssertEqual(state.searchText, "")
    }

    func testBackToRootResetsMode() {
        let state = CommandPaletteState()
        state.mode = .markdownPicker
        state.searchText = "readme"

        state.backToRoot()

        XCTAssertEqual(state.mode, .root)
        XCTAssertEqual(state.searchText, "")
    }

    func testCloseResetsMode() {
        let state = CommandPaletteState()
        state.open()
        state.enterMarkdownPicker()
        state.searchText = "foo"

        state.close()

        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.mode, .root)
        XCTAssertEqual(state.searchText, "")
    }

    func testDefaultModeIsRoot() {
        let state = CommandPaletteState()
        XCTAssertEqual(state.mode, .root)
    }
}
