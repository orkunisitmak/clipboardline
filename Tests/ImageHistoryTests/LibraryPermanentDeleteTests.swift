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
        // The fixture Trash names each arrival "<UUID>-<original name>"; other
        // library housekeeping may also use it, so look for the files by name.
        let trashed = try FileManager.default.contentsOfDirectory(atPath: f.folder.appendingPathComponent(".test-trash").path)
        XCTAssertTrue(trashed.contains { $0.hasSuffix("-" + copy.lastPathComponent) }, "It goes to the system Trash")
        XCTAssertFalse(trashed.contains { $0.hasSuffix("-" + original.lastPathComponent) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Originals elsewhere are never touched")
        XCTAssertEqual(try library.collections().map(\.id), [folder], "The folder itself stays")
        XCTAssertEqual(try library.tags().count, 1, "The tag itself stays")
        XCTAssertTrue(try library.collections(for: owned.id).isEmpty)
    }

    func testTextDragFileLeavesWithTheRecord() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let text = try XCTUnwrap(library.captureText("private note"))
        let file = try LibraryTransfer.materialize(text, store: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try library.trash([text.id])
        XCTAssertEqual(try library.deletePermanently([text.id]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "The drag copy of the text does not outlive it")
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

    func testConfirmedSnapshotSparesAnItemTrashedAgainAfterConfirmation() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try library.captureImage(try f.image())
        try library.trash([record.id])
        let snapshot = try library.trashSnapshot([record.id])
        XCTAssertEqual(Set(snapshot.keys), [record.id])
        // Restored and trashed again while the confirmation was open.
        try library.restore([record.id]); try library.trash([record.id])
        XCTAssertEqual(try library.deletePermanently(confirmed: snapshot), 0, "A new Trash generation was not confirmed")
        XCTAssertNotNil(try library.item(record.id))
        XCTAssertEqual(try library.deletePermanently(confirmed: library.trashSnapshot([record.id])), 1)
    }

    func testLargeTrashIsErasedInChunksAndLeavesLiveItemsSearchable() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        // More items than one statement takes, so the last chunk is a partial one.
        let trashed = try (0..<1_203).map { try XCTUnwrap(library.captureText("bulk entry number \($0)")).id }
        let folder = try library.createCollection("Work")
        try library.assign([trashed[0], trashed[600], trashed[1_202]], to: folder); try library.addTag("tag", to: [trashed[499], trashed[500]])
        let live = try XCTUnwrap(library.captureText("bulk entry that stays"))
        try library.trash(trashed)
        XCTAssertEqual(try library.query(LibraryQuery(scope: .trash, search: "bulk"), limit: 2_000).count, 1_203)

        XCTAssertEqual(try library.deletePermanently(confirmed: library.trashSnapshot(library.trashedIDs())), 1_203)
        XCTAssertTrue(try library.trashedIDs().isEmpty)
        for id in [trashed[0], trashed[499], trashed[500], trashed[1_202]] { XCTAssertNil(try library.item(id)) }
        XCTAssertTrue(try library.query(LibraryQuery(scope: .trash, search: "bulk"), limit: 2_000).isEmpty, "No search entry outlives its item")
        XCTAssertEqual(try library.query(LibraryQuery(scope: .recent, search: "bulk"), limit: 2_000).map(\.id), [live.id])
        XCTAssertTrue(try library.query(LibraryQuery(scope: .collection(folder)), limit: 2_000).isEmpty)
        // The same text can be captured again as a new item afterwards.
        XCTAssertNotNil(try library.captureText("bulk entry number 7"))
    }
}
