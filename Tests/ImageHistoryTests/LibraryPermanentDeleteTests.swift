import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class LibraryPermanentDeleteTests: HistoryTestCase {
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }

    func testDeletePermanentlyErasesTrashedRecordsAndOnlyTheAppsOwnCopies() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let copy = try f.image()                  // "Clipboard <UUID>.png" in the app's folder
        let original = try f.image(owned: false)  // a file elsewhere, like the Desktop
        let owned = try library.captureImage(copy), external = try library.captureImage(original)
        let text = try XCTUnwrap(library.captureText("erase me"))
        let folder = try library.createCollection("Work")
        try library.assign([owned.id, external.id], to: folder); try library.addTag("tag", to: [owned.id, text.id])
        try library.trash([owned.id, external.id, text.id])

        XCTAssertEqual(try library.deletePermanently([owned.id, external.id, text.id]), 3)
        for id in [owned.id, external.id, text.id] { XCTAssertNil(try library.item(id)) }
        XCTAssertTrue(try library.trashedIDs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "The app's own copy leaves its folder")
        let systemTrash = f.folder.appendingPathComponent(".test-trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: systemTrash.path).count, 1, "It goes to the system Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Originals elsewhere are never touched")
        XCTAssertEqual(try library.collections().map(\.id), [folder], "The folder itself stays")
        XCTAssertEqual(try library.tags().count, 1, "The tag itself stays")
        XCTAssertTrue(try library.collections(for: owned.id).isEmpty)
    }

    func testItemsOutsideTrashAndFilesStillInUseAreKept() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let copy = try f.image()
        let first = try library.captureImage(copy)
        try library.trash([first.id])
        // The same file captured again while the first record is in Trash.
        let second = try library.captureImage(copy)
        XCTAssertNotEqual(first.id, second.id)

        XCTAssertEqual(try library.deletePermanently([first.id, second.id]), 1, "Only Trash items are erased")
        XCTAssertNil(try library.item(first.id))
        XCTAssertNotNil(try library.item(second.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "A file another record uses stays")
        XCTAssertEqual(try library.deletePermanently(library.trashedIDs()), 0, "An empty Trash erases nothing")
    }
}
