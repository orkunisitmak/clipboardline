import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ActionBarRoutingTests: HistoryTestCase {
    private func setup() throws -> (SyntheticFixture, LibraryStore, Line, AppDelegate) {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture()
        let store = try LibraryStore(defaults: fixture.defaults, inbox: fixture.inbox, now: { fixture.date })
        let line = Line(defaults: fixture.defaults, inbox: fixture.inbox, now: { fixture.date }, breeze: false,
            copyImage: { _ in }, copyText: { _ in }, library: store)
        let board = NSPasteboard(name: .init("action-bar-routing-\(UUID())"))
        return (fixture, store, line, AppDelegate(line: line, watchesFiles: false, copyPasteboard: board))
    }
    private func run(_ action: KeyboardAction, palette: CommandPalette) throws {
        let index = try XCTUnwrap(palette.visibleCommands.firstIndex { $0.id == action.rawValue })
        XCTAssertTrue(palette.visibleCommands[index].isEnabled)
        palette.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        palette.executeSelected()
    }

    func testLibraryActionsRestoreSelectsTheFirstRemainingTrashItem() throws {
        let (f, store, _, delegate) = try setup(); defer { f.cleanup() }
        let records = try ["first trashed note", "second trashed note", "third trashed note"].map { try XCTUnwrap(store.captureText($0)) }
        try store.trash(records.map(\.id))
        delegate.showLibrary()
        let model = try XCTUnwrap(delegate.libraryController).model
        defer { delegate.commandPalette?.window.close(); delegate.libraryController?.window?.close() }
        model.changeScope(.trash)
        let deadline = Date().addingTimeInterval(8)
        func wait(_ predicate: () -> Bool) { while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) } }
        wait { model.ids.count == 3 && !model.loading }
        let order = model.ids
        XCTAssertTrue(model.select(order[1]))
        delegate.showCommands(origin: .library)
        let palette = try XCTUnwrap(delegate.commandPalette)
        let index = try XCTUnwrap(palette.visibleCommands.firstIndex { $0.id == "menu.restore" })
        XCTAssertTrue(palette.visibleCommands[index].isEnabled)
        palette.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        palette.executeSelected()
        wait { model.ids.count == 2 && !model.loading }
        XCTAssertEqual(model.ids, [order[0], order[2]])
        XCTAssertEqual(model.focusedID, order[0]); XCTAssertEqual(model.inspected?.id, order[0])
    }

    func testShelfButtonOriginWinsOverKeySettingsAndKeepsCapturedPinTarget() throws {
        let (f, store, line, delegate) = try setup(); defer { f.cleanup() }
        _ = line.texts.add("Captured pin target"); _ = line.texts.add("Different selection")
        let original = line.texts.entries[1].id, different = line.texts.entries[0].id
        line.focusShelf(.texts, requestFocus: false); line.texts.select(original, width: 1000)
        delegate.showSettings()
        defer { delegate.commandPalette?.window.close(); delegate.settingsController?.window?.close() }
        delegate.showCommands(origin: .line)
        let palette = try XCTUnwrap(delegate.commandPalette)
        line.texts.select(different, width: 1000)
        try run(.pin, palette: palette)
        XCTAssertEqual(try store.item(original)?.favorite, true)
        XCTAssertEqual(try store.item(different)?.favorite, false)
    }

    func testTakeDownUsesCapturedIDsAndAdvancesFromCapturedFocusAfterSelectionChanges() throws {
        let (f, store, line, delegate) = try setup(); defer { f.cleanup() }
        for value in ["Oldest", "Middle", "Newest"] { _ = line.texts.add(value) }
        line.focusShelf(.texts, requestFocus: false)
        let ordered = line.texts.displayEntries.map(\.id), target = ordered[0], replacement = ordered[2]
        line.texts.select(target, width: 1000)
        delegate.showCommands(origin: .line)
        defer { delegate.commandPalette?.window.close() }
        let palette = try XCTUnwrap(delegate.commandPalette)
        line.texts.select(replacement, width: 1000)
        try run(.removeFromLine, palette: palette)
        XCTAssertEqual(try store.item(target)?.onShelf, false)
        XCTAssertEqual(try store.item(replacement)?.onShelf, true)
        XCTAssertEqual(line.texts.focusedID, ordered[1])
        line.undoShelfRemoval()
        XCTAssertEqual(try store.item(target)?.onShelf, true)
    }

    func testPreviewActionUsesFocusedItemWithinMultiSelection() throws {
        let (f, _, line, delegate) = try setup(); defer { f.cleanup() }
        for value in ["First", "Second", "Third"] { _ = line.texts.add(value) }
        line.focusShelf(.texts, requestFocus: false)
        line.texts.selectAll()
        let focused = line.texts.entries.last!.id
        line.texts.select(focused, extending: true, width: 1000)
        XCTAssertTrue(line.texts.selectedIDs.count > 1)
        delegate.showCommands(origin: .line)
        defer { delegate.commandPalette?.window.close(); delegate.previewWindow?.close() }
        try run(.preview, palette: XCTUnwrap(delegate.commandPalette))
        XCTAssertEqual(delegate.previewSession?.currentID, focused)
    }

    func testCopyActionUsesCapturedTextAndRecordsCopyWithoutTouchingGeneralClipboard() throws {
        let (f, store, line, _) = try setup(); defer { f.cleanup() }
        _ = line.texts.add("Captured clipboard text"); _ = line.texts.add("New selection text")
        let original = line.texts.entries[1].id, different = line.texts.entries[0].id
        let board = NSPasteboard(name: .init("action-bar-copy-\(UUID())"))
        let delegate = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        let otherCopiedAt = try store.item(different)?.lastCopiedAt
        f.date.addTimeInterval(5)
        line.focusShelf(.texts, requestFocus: false); line.texts.select(original, width: 1000)
        delegate.showCommands(origin: .line)
        defer { delegate.commandPalette?.window.close() }
        let palette = try XCTUnwrap(delegate.commandPalette)
        line.texts.select(different, width: 1000)
        try run(.copy, palette: palette)
        XCTAssertEqual(board.string(forType: .string), "Captured clipboard text")
        XCTAssertEqual(try store.item(original)?.lastCopiedAt, f.date)
        XCTAssertEqual(try store.item(different)?.lastCopiedAt, otherCopiedAt)
    }
}
