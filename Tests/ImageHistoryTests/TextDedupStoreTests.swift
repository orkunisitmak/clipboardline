import AppKit
import CryptoKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class TextDedupStoreTests: HistoryTestCase {
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }
    private func text(_ body: String, at date: Date) -> LibraryRecord {
        var record = LibraryRecord(id: UUID(), kind: .text, createdAt: date, updatedAt: date)
        record.text = body
        return record
    }
    private func live(_ library: LibraryStore) throws -> [LibraryRecord] {
        try library.query(LibraryQuery(scope: .shelf, kind: .text))
    }

    func testRecaptureMovesExistingExactTextToNewestWithoutGrowingHistory() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let a = try XCTUnwrap(library.captureText("First value\nİstanbul 👋"))
        f.date.addTimeInterval(1)
        let b = try XCTUnwrap(library.captureText("Second value"))
        f.date.addTimeInterval(1)
        let refreshed = try XCTUnwrap(library.captureText(a.text!))
        XCTAssertEqual(refreshed.id, a.id)
        XCTAssertEqual(refreshed.createdAt, f.date)
        XCTAssertEqual(refreshed.lastCapturedAt, f.date)
        XCTAssertEqual(refreshed.lastCopiedAt, f.date)
        XCTAssertEqual(try live(library).map(\.id), [a.id, b.id])
        let db = try LibraryDatabase(url: library.databaseURL, readOnly: true)
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM items").first?["n"]?.number, 2)
        XCTAssertTrue(try library.query(LibraryQuery(scope: .trash)).isEmpty)
    }

    func testRecaptureAndNewCaptureStayNewestWithAnUnchangedClock() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let a = try XCTUnwrap(library.captureText("Frozen A"))
        let b = try XCTUnwrap(library.captureText("Frozen B"))
        XCTAssertEqual(try live(library).map(\.id), [b.id, a.id])
        let repeatedA = try XCTUnwrap(library.captureText("Frozen A"))
        XCTAssertEqual(repeatedA.id, a.id)
        XCTAssertEqual(try live(library).map(\.id), [a.id, b.id])
        let c = try XCTUnwrap(library.captureText("Frozen C"))
        XCTAssertEqual(try live(library).map(\.id), [c.id, a.id, b.id])
        for value in [repeatedA, c] {
            XCTAssertEqual(value.lastCapturedAt, f.date)
            XCTAssertEqual(value.lastCopiedAt, f.date)
            XCTAssertEqual(value.updatedAt, f.date)
        }
        XCTAssertEqual(try library.query(LibraryQuery(scope: .recent, kind: .text)).map(\.id), [c.id, a.id, b.id])
    }

    func testBackwardClockKeepsLatestCaptureFirstWithActualCaptureTime() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let a = try XCTUnwrap(library.captureText("Clock A"))
        f.date.addTimeInterval(10)
        let b = try XCTUnwrap(library.captureText("Clock B"))
        f.date.addTimeInterval(-60)
        let repeatedA = try XCTUnwrap(library.captureText("Clock A"))
        XCTAssertEqual(repeatedA.id, a.id)
        XCTAssertEqual(repeatedA.lastCapturedAt, f.date)
        XCTAssertEqual(repeatedA.lastCopiedAt, f.date)
        XCTAssertEqual(repeatedA.updatedAt, f.date)
        XCTAssertEqual(try live(library).map(\.id), [a.id, b.id])
        let c = try XCTUnwrap(library.captureText("Clock C"))
        XCTAssertEqual(c.lastCapturedAt, f.date)
        XCTAssertEqual(try live(library).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(try store(f).shelfItems(.text).map(\.id), [c.id, a.id, b.id])
    }

    func testRecapturingFrontItemRefreshesTimeAndPreservesNamedPinAndOrganization() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), body = "opaque-synthetic-value-29\nsecond line"
        let original = try XCTUnwrap(library.captureText(body))
        let folder = try library.createCollection("References")
        try library.assign([original.id], to: folder)
        try library.addTag("Project", to: [original.id])
        try library.nameAndPin(original.id, name: "Friendly label")
        try library.update(original.id) { $0.note = "Personal annotation" }
        let before = try XCTUnwrap(library.item(original.id))
        f.date.addTimeInterval(14 * 86400)
        let refreshed = try XCTUnwrap(library.captureText(body))
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.createdAt, f.date)
        XCTAssertEqual(refreshed.updatedAt, f.date)
        XCTAssertTrue(refreshed.favorite)
        XCTAssertEqual(refreshed.title, before.title)
        XCTAssertEqual(refreshed.note, before.note)
        XCTAssertEqual(refreshed.retainedAt, before.retainedAt)
        XCTAssertEqual(Data((refreshed.text ?? "").utf8), Data(body.utf8))
        XCTAssertEqual(try library.collections(for: original.id).map(\.id), [folder])
        XCTAssertEqual(try library.tags(for: original.id).map(\.name), ["Project"])
        XCTAssertEqual(try live(library).count, 1)
        XCTAssertEqual(try store(f).item(original.id), refreshed)
    }

    func testRecaptureReturnsRetainedOffShelfTextAndInvalidatesOldRemovalUndo() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Saved value"))
        try library.pin([original.id])
        try library.removeFromShelf([original.id])
        XCTAssertTrue(try live(library).isEmpty)
        f.date.addTimeInterval(1)
        let refreshed = try XCTUnwrap(library.captureText("Saved value"))
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertTrue(refreshed.onShelf)
        XCTAssertTrue(refreshed.favorite)
        XCTAssertNil(refreshed.deletedAt)
        XCTAssertTrue(try library.undoShelfRemoval().isEmpty)
        XCTAssertEqual(try live(library).map(\.id), [original.id])
    }

    func testExpiredCopiesLeaveTheShelfAtLaunchAndOnTheNextCopy() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        f.defaults.set(1, forKey: HistoryRetention.key(.text))
        let old = try XCTUnwrap(store(f).captureText("Copied two days ago"))
        f.date.addTimeInterval(2 * 86400)
        let relaunched = try store(f)
        XCTAssertNotNil(try relaunched.item(old.id)?.deletedAt)
        XCTAssertTrue(try live(relaunched).isEmpty)

        let kept = try XCTUnwrap(relaunched.captureText("Copied today"))
        f.date.addTimeInterval(2 * 86400)
        let next = try XCTUnwrap(relaunched.captureText("Copied after two more days"))
        XCTAssertNotNil(try relaunched.item(kept.id)?.deletedAt)
        XCTAssertEqual(try live(relaunched).map(\.id), [next.id])
    }

    func testRecaptureNeverResurrectsAnExplicitlyTrashedRecord() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Trashed value"))
        try library.nameAndPin(original.id, name: "Old label")
        try library.trash([original.id])
        let trashed = try XCTUnwrap(library.item(original.id))
        f.date.addTimeInterval(1)
        let replacement = try XCTUnwrap(library.captureText("Trashed value"))
        XCTAssertTrue(replacement.id != original.id)
        XCTAssertEqual(try library.item(original.id), trashed)
        XCTAssertFalse(replacement.favorite)
        XCTAssertTrue(replacement.title.isEmpty)
        XCTAssertEqual(try live(library).map(\.id), [replacement.id])
        XCTAssertEqual(try library.query(LibraryQuery(scope: .trash)).map(\.id), [original.id])
    }

    func testImportedDuplicatesConsolidateOnRecaptureAndPreserveAllOrganization() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), body = "Repeated imported text"
        var old = text(body + "\n", at: f.date.addingTimeInterval(-3))
        old.title = "Retained name"; old.note = "Retained note"
        old.favorite = true; old.retainedAt = f.date.addingTimeInterval(-30)
        var middle = text("\r\n" + body, at: f.date.addingTimeInterval(-2))
        middle.retainedAt = f.date.addingTimeInterval(-20)
        let newest = text(body, at: f.date.addingTimeInterval(-1))
        try library.importRecords([old, middle, newest])
        let folderA = try library.createCollection("First folder"), folderB = try library.createCollection("Second folder")
        try library.assign([old.id], to: folderA); try library.assign([middle.id], to: folderB)
        try library.addTag("older-tag", to: [old.id]); try library.addTag("middle-tag", to: [middle.id])
        let oldBefore = try XCTUnwrap(library.item(old.id)), middleBefore = try XCTUnwrap(library.item(middle.id))
        XCTAssertEqual(try live(library).count, 3)
        f.date.addTimeInterval(5)
        let captured = try XCTUnwrap(library.captureText(body))
        XCTAssertEqual(captured.id, newest.id)
        XCTAssertEqual(try live(library).map(\.id), [newest.id])
        XCTAssertTrue(captured.favorite)
        XCTAssertEqual(captured.retainedAt, old.retainedAt)
        XCTAssertEqual(captured.title, old.title); XCTAssertEqual(captured.note, old.note)
        XCTAssertEqual(Set(try library.collections(for: captured.id).map(\.id)), Set([folderA, folderB]))
        XCTAssertEqual(Set(try library.tags(for: captured.id).map(\.name)), Set(["older-tag", "middle-tag"]))
        XCTAssertEqual(try library.query(LibraryQuery(search: "middle-tag")).map(\.id), [newest.id])
        for before in [oldBefore, middleBefore] {
            let removed = try XCTUnwrap(library.item(before.id))
            XCTAssertEqual(removed.deletedAt, f.date); XCTAssertFalse(removed.onShelf)
            XCTAssertEqual(removed.text, before.text); XCTAssertEqual(removed.title, before.title)
            XCTAssertEqual(removed.note, before.note); XCTAssertEqual(removed.favorite, before.favorite)
            XCTAssertEqual(try library.collections(for: removed.id).count, 1)
            XCTAssertEqual(try library.tags(for: removed.id).count, 1)
        }
        XCTAssertEqual(Set(try library.query(LibraryQuery(scope: .trash)).map(\.id)), Set([old.id, middle.id]))
    }

    func testRecaptureDoesNotOverwriteNewerCustomNameOrNoteWithDuplicateMetadata() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        var old = text("Repeated", at: f.date.addingTimeInterval(-1)); old.title = "Old name"; old.note = "Old note"
        var newest = text("Repeated", at: f.date); newest.title = "Current name"; newest.note = "Current note"
        try library.importRecords([old, newest])
        f.date.addTimeInterval(1)
        let refreshed = try XCTUnwrap(library.captureText("Repeated"))
        XCTAssertEqual(refreshed.id, newest.id)
        XCTAssertEqual(refreshed.title, newest.title); XCTAssertEqual(refreshed.note, newest.note)
        XCTAssertEqual(try library.item(old.id)?.title, old.title)
    }

    func testNormalizedCopiesReuseIdentityAndPreserveNewestLiteralBytes() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let body = "Restoran Listesi Çıkart"
        let original = try XCTUnwrap(library.captureText(body))
        let folder = try library.createCollection("Named references")
        try library.assign([original.id], to: folder)
        try library.addTag("useful", to: [original.id])
        try library.nameAndPin(original.id, name: "Restaurant plan")
        f.date.addTimeInterval(1)
        let other = try XCTUnwrap(library.captureText("Different text"))
        for value in [body + "\n", "\r\n" + body + "\r\n\r\n", body] {
            f.date.addTimeInterval(1)
            let captured = try XCTUnwrap(library.captureText(value))
            XCTAssertEqual(captured.id, original.id)
            XCTAssertEqual(Data((captured.text ?? "").utf8), Data(value.utf8))
            XCTAssertEqual(captured.title, "Restaurant plan")
            XCTAssertTrue(captured.favorite)
            XCTAssertEqual(try library.collections(for: captured.id).map(\.id), [folder])
            XCTAssertEqual(try library.tags(for: captured.id).map(\.name), ["useful"])
            XCTAssertEqual(try live(library).map(\.id), [original.id, other.id])
        }
        let composed = try XCTUnwrap(library.captureText("café\nsecond line"))
        let variants = ["cafe\u{301}\r\nsecond line", "\ncafé\rsecond line\n"]
        for value in variants {
            f.date.addTimeInterval(1)
            let captured = try XCTUnwrap(library.captureText(value))
            XCTAssertEqual(captured.id, composed.id)
            XCTAssertEqual(Data((captured.text ?? "").utf8), Data(value.utf8))
        }
        XCTAssertEqual(try live(library).count, 3)
    }

    func testWhitespaceCaseAndInvisibleContentRemainDistinct() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let values = ["Value", "value", " Value", "Value ", "\tValue", "Value\t", "\t", " ",
                      "first\nsecond", "first\n\nsecond", "Value\u{200B}", "Value\u{2028}", "İ", "I"]
        var ids = [UUID]()
        for value in values {
            f.date.addTimeInterval(1)
            let record = try XCTUnwrap(library.captureText(value))
            ids.append(record.id)
            XCTAssertEqual(Data((record.text ?? "").utf8), Data(value.utf8))
        }
        XCTAssertEqual(Set(ids).count, values.count)
        for (value, id) in zip(values, ids) {
            f.date.addTimeInterval(1)
            let recaptured = try XCTUnwrap(library.captureText(value))
            XCTAssertEqual(recaptured.id, id)
            XCTAssertEqual(Data((recaptured.text ?? "").utf8), Data(value.utf8))
        }
        XCTAssertEqual(try live(library).count, values.count)
    }

    func testNewlineOnlyCopiesNormalizeLineEndingsWithoutLosingLineCount() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let one = try XCTUnwrap(library.captureText("\n"))
        let two = try XCTUnwrap(library.captureText("\n\n"))
        XCTAssertTrue(one.id != two.id)
        for (value, id) in [("\r\n", one.id), ("\r\n\r\n", two.id), ("\r", one.id)] {
            f.date.addTimeInterval(1)
            let captured = try XCTUnwrap(library.captureText(value))
            XCTAssertEqual(captured.id, id)
            XCTAssertEqual(Data((captured.text ?? "").utf8), Data(value.utf8))
        }
        XCTAssertEqual(try live(library).count, 2)
    }

    func testEditedTextIdentityTracksNewPayloadAndSurvivesRestart() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Before edit"))
        try library.update(original.id) { $0.text = "After edit 👋\nsecond line" }
        let reopened = try store(f)
        f.date.addTimeInterval(1)
        let newBefore = try XCTUnwrap(reopened.captureText("Before edit"))
        XCTAssertTrue(newBefore.id != original.id)
        f.date.addTimeInterval(1)
        let current = try XCTUnwrap(reopened.captureText("After edit 👋\nsecond line"))
        XCTAssertEqual(current.id, original.id)
        XCTAssertEqual(Data((current.text ?? "").utf8), Data("After edit 👋\nsecond line".utf8))
        XCTAssertEqual(try live(reopened).map(\.id), [original.id, newBefore.id])
        XCTAssertEqual(try reopened.query(LibraryQuery(scope: .shelf, search: "Before edit")).map(\.id), [newBefore.id])
    }

    func testExistingDatabaseBackfillsIdentityWithoutDeletingOrRewritingRecords() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let older = text("Legacy duplicate", at: f.date.addingTimeInterval(-2))
        let newer = text("Legacy duplicate", at: f.date.addingTimeInterval(-1))
        let different = text("Legacy other", at: f.date)
        try library.importRecords([older, newer, different])
        let db = try LibraryDatabase(url: library.databaseURL)
        let payloads = try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }
        try db.execute("DROP TABLE text_identity")
        try db.execute("DELETE FROM metadata WHERE key='text-identity-v1'")
        let reopened = try store(f)
        XCTAssertEqual(try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }, payloads)
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM text_identity").first?["n"]?.number, 3)
        XCTAssertEqual(try live(reopened).count, 3)
        f.date.addTimeInterval(1)
        XCTAssertEqual(try reopened.captureText("Legacy duplicate")?.id, newer.id)
        XCTAssertEqual(Set(try live(reopened).map(\.id)), Set([newer.id, different.id]))
        XCTAssertEqual(try reopened.item(older.id)?.text, older.text)
    }

    func testRestartRepairsIdentityAfterLegacyWriterEditsPayload() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Before legacy edit"))
        let db = try LibraryDatabase(url: library.databaseURL)
        var edited = original; edited.text = "After legacy edit"; edited.updatedAt = f.date
        // Earlier versions update the record payload without knowing about
        // the identity side table. The database invalidates that stale key.
        try db.execute("UPDATE items SET payload=? WHERE id=?", [.blob(try JSONEncoder().encode(edited)), .text(original.id.uuidString)])
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM text_identity WHERE item=?", [.text(original.id.uuidString)]).first?["n"]?.number, 0)
        let reopened = try store(f)
        f.date.addTimeInterval(1)
        XCTAssertEqual(try reopened.captureText("After legacy edit")?.id, original.id)
        f.date.addTimeInterval(1)
        let freshOriginal = try XCTUnwrap(reopened.captureText("Before legacy edit"))
        XCTAssertTrue(freshOriginal.id != original.id)
        XCTAssertEqual(try reopened.item(original.id)?.text, "After legacy edit")
        XCTAssertEqual(try live(reopened).count, 2)
    }

    func testVersionOneDigestMigrationPreservesPayloadsAndMatchesNormalizedRecopy() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let original = try XCTUnwrap(library.captureText("cafe\u{301}\r\nsecond line\n"))
        _ = try library.captureText("Separate legacy record")
        let db = try LibraryDatabase(url: library.databaseURL)
        let payloads = try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }
        // Recreate the actual three-column v1 table used by review.35/.36.
        try db.execute("DROP TABLE text_identity")
        try db.execute("CREATE TABLE text_identity(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,digest BLOB NOT NULL,captured REAL NOT NULL)")
        for item in try live(library) {
            let digest = Data(SHA256.hash(data: Data((item.text ?? "").utf8)))
            try db.execute("INSERT INTO text_identity(item,digest,captured) VALUES(?,?,?)", [.text(item.id.uuidString), .blob(digest), .real(item.createdAt.timeIntervalSince1970)])
        }
        let reopened = try store(f)
        XCTAssertEqual(try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }, payloads)
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM text_identity WHERE version=2").first?["n"]?.number, 2)
        f.date.addTimeInterval(1)
        let captured = try XCTUnwrap(reopened.captureText("café\nsecond line"))
        XCTAssertEqual(captured.id, original.id)
        XCTAssertEqual(Data((captured.text ?? "").utf8), Data("café\nsecond line".utf8))
        XCTAssertEqual(try live(reopened).count, 2)
    }

    func testCurrentCaptureRepairsMissingIdentityAfterExternalLegacyWriterEdit() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Before external edit"))
        let db = try LibraryDatabase(url: library.databaseURL)
        var edited = original; edited.text = "After external edit\r\n"; edited.updatedAt = f.date
        try db.execute("UPDATE items SET payload=? WHERE id=?", [.blob(try JSONEncoder().encode(edited)), .text(original.id.uuidString)])
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM text_identity WHERE item=?", [.text(original.id.uuidString)]).first?["n"]?.number, 0)
        f.date.addTimeInterval(1)
        let captured = try XCTUnwrap(library.captureText("After external edit"))
        XCTAssertEqual(captured.id, original.id)
        XCTAssertEqual(Data((captured.text ?? "").utf8), Data("After external edit".utf8))
        XCTAssertEqual(try live(library).count, 1)
        XCTAssertEqual(try db.rows("SELECT version FROM text_identity WHERE item=?", [.text(original.id.uuidString)]).first?["version"]?.number, 2)
    }

    func testNormalizedRecaptureRefreshesMaterializedFileWithNewestExactBytes() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let texts = TextHistory(defaults: f.defaults, folder: f.inbox.appendingPathComponent("Texts"), now: { f.date }, library: library)
        let original = try XCTUnwrap(library.captureText("café"))
        let file = try texts.materialize(try XCTUnwrap(texts.entries.first))
        for value in ["cafe\u{301}", "\ncafé\r\n"] {
            f.date.addTimeInterval(1)
            let captured = try XCTUnwrap(library.captureText(value))
            XCTAssertEqual(captured.id, original.id)
            XCTAssertEqual(try Data(contentsOf: file), Data(value.utf8))
            let entry = try XCTUnwrap(texts.entries.first)
            XCTAssertEqual(Data(entry.text.utf8), Data(value.utf8))
            XCTAssertEqual(try texts.materialize(entry), file)
        }
    }

    func testCanonicalOnlyEditRefreshesAdapterCopyAndMaterializedBytesWithoutDateChange() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        let original = try XCTUnwrap(library.captureText("café"))
        var copied: String?
        let texts = TextHistory(defaults: f.defaults, folder: f.inbox.appendingPathComponent("Texts"), now: { f.date }, copyText: { copied = $0 }, library: library)
        let before = try XCTUnwrap(texts.entries.first)
        let file = try texts.materialize(before), edited = "cafe\u{301}"
        XCTAssertTrue(texts.updateText(original.id, to: edited))
        let after = try XCTUnwrap(texts.entries.first)
        XCTAssertEqual(after.id, original.id)
        XCTAssertEqual(after.capturedAt, before.capturedAt)
        XCTAssertEqual(Data(after.text.utf8), Data(edited.utf8))
        XCTAssertEqual(Data(try XCTUnwrap(library.item(original.id)?.text).utf8), Data(edited.utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
        texts.copy(original.id)
        XCTAssertEqual(Data(try XCTUnwrap(copied).utf8), Data(edited.utf8))
    }

    func testNormalizedRecaptureRejectsUnsafeFilesAndRollsBackFileAfterDatabaseFailure() throws {
        for failure in ["tamper", "symlink", "database"] {
            let f = try SyntheticFixture(); defer { f.cleanup() }
            let library = try store(f)
            let texts = TextHistory(defaults: f.defaults, folder: f.inbox.appendingPathComponent("Texts"), now: { f.date }, library: library)
            let original = try XCTUnwrap(library.captureText("Materialized original"))
            let file = try texts.materialize(try XCTUnwrap(texts.entries.first))
            let db = try LibraryDatabase(url: library.databaseURL)
            let payloads = try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }
            let revision = library.revision
            var expected = Data("Materialized original".utf8)
            if failure == "tamper" {
                expected = Data("Externally modified file".utf8); try expected.write(to: file)
            } else if failure == "symlink" {
                let target = f.folder.appendingPathComponent("outside.txt")
                try expected.write(to: target); try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            } else {
                try db.execute("CREATE TRIGGER reject_materialized_recapture BEFORE UPDATE ON items WHEN NEW.id='\(original.id.uuidString)' BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END")
            }
            f.date.addTimeInterval(1)
            XCTAssertThrowsError(try library.captureText("Materialized original\n"))
            XCTAssertEqual(library.revision, revision)
            XCTAssertEqual(try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }, payloads)
            XCTAssertEqual(try Data(contentsOf: file), expected)
            XCTAssertEqual(Data(try XCTUnwrap(texts.entries.first?.text).utf8), Data("Materialized original".utf8))
            if failure == "symlink" { XCTAssertTrue(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true) }
        }
    }

    func testFailedConsolidationRollsBackRowsMembershipsIdentitySearchAndRevision() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        var old = text("Transaction value", at: f.date.addingTimeInterval(-1))
        old.title = "Older title"; old.favorite = true; old.retainedAt = f.date
        let newest = text("Transaction value", at: f.date)
        try library.importRecords([old, newest])
        let folder = try library.createCollection("Older folder")
        try library.assign([old.id], to: folder); try library.addTag("older-search-tag", to: [old.id])
        let db = try LibraryDatabase(url: library.databaseURL)
        let recordsBefore = try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }
        func strings(_ sql: String, _ columns: [String]) throws -> [String] {
            try db.rows(sql).map { row in columns.map { row[$0]?.string ?? row[$0]?.data?.base64EncodedString() ?? "" }.joined(separator: "|") }
        }
        let membershipsBefore = try strings("SELECT item,collection FROM item_collections ORDER BY item,collection", ["item", "collection"])
        let tagsBefore = try strings("SELECT item,tag FROM item_tags ORDER BY item,tag", ["item", "tag"])
        let identitiesBefore = try strings("SELECT item,digest,CAST(captured AS TEXT) AS captured FROM text_identity ORDER BY item", ["item", "digest", "captured"])
        let ftsBefore = try strings("SELECT id,content FROM search_fts ORDER BY id", ["id", "content"])
        let revision = library.revision, searchRevision = library.searchRevision
        try db.execute("CREATE TRIGGER reject_text_recapture BEFORE UPDATE ON items WHEN NEW.id='\(newest.id.uuidString)' AND NEW.created>OLD.created BEGIN SELECT RAISE(ABORT,'synthetic recapture failure'); END")
        f.date.addTimeInterval(10)
        XCTAssertThrowsError(try library.captureText("Transaction value"))
        XCTAssertEqual(library.revision, revision); XCTAssertEqual(library.searchRevision, searchRevision)
        XCTAssertEqual(try db.rows("SELECT payload FROM items ORDER BY id").compactMap { $0["payload"]?.data }, recordsBefore)
        XCTAssertEqual(try strings("SELECT item,collection FROM item_collections ORDER BY item,collection", ["item", "collection"]), membershipsBefore)
        XCTAssertEqual(try strings("SELECT item,tag FROM item_tags ORDER BY item,tag", ["item", "tag"]), tagsBefore)
        XCTAssertEqual(try strings("SELECT item,digest,CAST(captured AS TEXT) AS captured FROM text_identity ORDER BY item", ["item", "digest", "captured"]), identitiesBefore)
        XCTAssertEqual(try strings("SELECT id,content FROM search_fts ORDER BY id", ["id", "content"]), ftsBefore)
        XCTAssertEqual(try live(library).count, 2)
        try db.execute("DROP TRIGGER reject_text_recapture")
        XCTAssertEqual(try library.captureText("Transaction value")?.id, newest.id)
        XCTAssertEqual(try live(library).count, 1)
    }

    func testRecaptureRenewsTemporaryRetentionFromMostRecentCopy() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f), original = try XCTUnwrap(library.captureText("Renewed temporary value"))
        f.date.addTimeInterval(1)
        let stale = try XCTUnwrap(library.captureText("Unchanged old value"))
        f.date.addTimeInterval(31 * 86400)
        let recaptured = try XCTUnwrap(library.captureText("Renewed temporary value"))
        XCTAssertEqual(recaptured.id, original.id)
        try library.prune()
        XCTAssertNil(try library.item(original.id)?.deletedAt)
        XCTAssertNotNil(try library.item(stale.id)?.deletedAt)
        f.date.addTimeInterval(31 * 86400)
        try library.prune()
        XCTAssertNotNil(try library.item(original.id)?.deletedAt)
    }

    func testBackwardClockUsesActualCaptureForExpiryWhilePinnedItemsRemain() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        f.defaults.set(30, forKey: HistoryRetention.key(.text))
        let library = try store(f), baseline = f.date
        let original = try XCTUnwrap(library.captureText("Recaptured before clock correction"))
        // A capture expires old copies, so the original is pinned across the clock jump.
        try library.pin([original.id])
        f.date = baseline.addingTimeInterval(100 * 86400)
        let future = try XCTUnwrap(library.captureText("Pinned future ordering anchor"))
        try library.pin([future.id])
        try library.update(original.id) { $0.favorite = false; $0.retainedAt = nil }
        f.date = baseline.addingTimeInterval(86400)
        let recaptured = try XCTUnwrap(library.captureText("Recaptured before clock correction"))
        let fresh = try XCTUnwrap(library.captureText("New after clock correction"))
        let pinned = try XCTUnwrap(library.captureText("Pinned after clock correction"))
        try library.pin([pinned.id])
        XCTAssertEqual(recaptured.id, original.id)
        XCTAssertEqual(recaptured.lastCapturedAt, f.date)
        XCTAssertEqual(fresh.lastCapturedAt, f.date)
        XCTAssertTrue(recaptured.createdAt > f.date)
        XCTAssertTrue(fresh.createdAt > f.date)
        f.date.addTimeInterval(29 * 86400)
        try library.prune()
        XCTAssertNil(try library.item(original.id)?.deletedAt)
        XCTAssertNil(try library.item(fresh.id)?.deletedAt)
        f.date.addTimeInterval(2 * 86400)
        // Shelf ordering dates are still far in the future, but expiry must
        // use the real most recent capture date rather than that sort key.
        XCTAssertTrue(recaptured.createdAt > f.date)
        XCTAssertTrue(fresh.createdAt > f.date)
        let reopened = try store(f)
        try reopened.prune()
        XCTAssertNotNil(try reopened.item(original.id)?.deletedAt)
        XCTAssertNotNil(try reopened.item(fresh.id)?.deletedAt)
        XCTAssertNil(try reopened.item(pinned.id)?.deletedAt)
        XCTAssertNil(try reopened.item(future.id)?.deletedAt)
        XCTAssertEqual(Set(try live(reopened).map(\.id)), Set([pinned.id, future.id]))
    }

    func testExactTextLookupUsesDigestIndexInsteadOfScanningPayloads() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let library = try store(f)
        for i in 0..<24 { _ = try library.captureText("Indexed text \(i)") }
        let db = try LibraryDatabase(url: library.databaseURL, readOnly: true)
        let digest = try XCTUnwrap(db.rows("SELECT digest FROM text_identity LIMIT 1").first?["digest"]?.data)
        let plan = try db.rows("EXPLAIN QUERY PLAN SELECT i.id FROM text_identity t JOIN items i ON i.id=t.item WHERE t.digest=? AND i.kind='text' AND i.deleted IS NULL ORDER BY i.created DESC,i.rowid DESC", [.blob(digest)]).compactMap { $0["detail"]?.string }.joined(separator: "\n")
        XCTAssertTrue(plan.contains("text_identity_digest"))
        XCTAssertFalse(plan.contains("SCAN i"))
        let newestPlan = try db.rows("EXPLAIN QUERY PLAN SELECT created FROM items WHERE kind='text' AND shelf=1 AND deleted IS NULL ORDER BY created DESC,rowid DESC LIMIT 1").compactMap { $0["detail"]?.string }.joined(separator: "\n")
        XCTAssertTrue(newestPlan.contains("shelf_capture_order"))
        XCTAssertTrue(newestPlan.contains("COVERING INDEX"))
        XCTAssertFalse(newestPlan.contains("TEMP B-TREE"))
    }
}
