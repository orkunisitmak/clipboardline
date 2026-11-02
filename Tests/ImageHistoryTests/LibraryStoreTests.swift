import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class LibraryStoreTests: HistoryTestCase {
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }
    func testMigrationPreservesTextBytesDatesFavoritesIDsAndOriginals() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let image = try f.image(owned: false), bytes = try Data(contentsOf: image)
        let history = f.history(); history.add(image); _ = try history.togglePin(image)
        let texts = f.texts(); texts.add("İstanbul 👋\n中文"); let text = texts.entries[0]; texts.togglePin(text.id)
        let prefs = f.defaults.data(forKey: "imageHistoryV1"), archive = try Data(contentsOf: texts.archive)
        let library = try store(f), values = try library.query(LibraryQuery())
        XCTAssertEqual(values.count, 2); XCTAssertTrue(values.allSatisfy { $0.favorite && $0.retainedAt != nil })
        XCTAssertEqual(try library.item(text.id)?.text, text.text); XCTAssertEqual(try library.item(text.id)?.createdAt, text.capturedAt)
        let imageRecord = try XCTUnwrap(values.first { $0.kind == .image })
        XCTAssertEqual(imageRecord.id, history.entries[0].id)
        XCTAssertEqual(try Data(contentsOf: image), bytes)
        XCTAssertEqual(f.defaults.data(forKey: "imageHistoryV1"), prefs); XCTAssertEqual(try Data(contentsOf: texts.archive), archive)
        XCTAssertEqual(try store(f).query(LibraryQuery()).map(\.id), values.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Backups").path))
    }
    func testCorruptSourceBlocksMigrationAndDoesNotOverwriteArchive() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let texts = f.texts(); texts.add("original"); let bad = Data("broken".utf8); try bad.write(to: texts.archive)
        var failed = false; do { _ = try store(f) } catch { failed = true }
        XCTAssertTrue(failed); XCTAssertEqual(try Data(contentsOf: texts.archive), bad)
        try Data("[]".utf8).write(to: texts.archive)
        XCTAssertEqual(try store(f).query(LibraryQuery(scope: .recent)).count, 0)
    }
    func testFolderTagOrFavoriteRetainsAcrossUnassignUnpinAndExpiry() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let first = try XCTUnwrap(library.captureText("folder item")), second = try XCTUnwrap(library.captureText("tag item")), third = try XCTUnwrap(library.captureText("favorite item"))
        let temporary = try XCTUnwrap(library.captureText("temporary")), folder = try library.createCollection("YouTube")
        try library.assign([first.id], to: folder); try library.addTag("İŞ", to: [second.id]); try library.toggleFavorite([third.id])
        try library.unassign(first.id, from: folder); let tag = try XCTUnwrap(library.tags().first); try library.removeTag(tag.id, from: second.id); try library.toggleFavorite([third.id])
        f.date = f.date.addingTimeInterval(90 * 86400); try library.prune()
        XCTAssertEqual(Set(try library.query(LibraryQuery()).map(\.id)), Set([first.id,second.id,third.id]))
        XCTAssertTrue(try library.item(temporary.id)?.deletedAt != nil)
        XCTAssertEqual(try library.query(LibraryQuery(scope: .unorganized)).count, 3)
    }
    func testCollectionsAreManyToManyNestedAndRemovalDoesNotDeleteContent() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try library.captureImage(try f.image(owned: false)), parent = try library.createCollection("YouTube"), child = try library.createCollection("Thumbnail", parent: parent), other = try library.createCollection("Referanslar")
        try library.assign([record.id], to: child); try library.assign([record.id], to: other)
        XCTAssertEqual(try library.collections(for: record.id).count, 2)
        XCTAssertEqual(try library.query(LibraryQuery(scope: .collection(parent))).first?.id, record.id)
        let value = try XCTUnwrap(library.item(record.id)); XCTAssertTrue(library.files.isAppCopy(try XCTUnwrap(value.fileURL)))
        try library.renameCollection(child, name: "Yeni isim"); try library.removeCollection(parent)
        XCTAssertEqual(try library.collections(for: record.id).map(\.id), [other])
        XCTAssertTrue(try library.item(record.id)?.retainedAt != nil)
        var failed = false; do { _ = try library.createCollection("child", parent: UUID()) } catch { failed = true }; XCTAssertTrue(failed)
    }
    func testPinnedImageWhoseManagedCopyIsGoneCanStillLeaveTheShelfGoToTrashAndRestore() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try library.captureImage(try f.image(owned: false))
        try library.toggleFavorite([record.id])
        let managed = try XCTUnwrap(library.item(record.id)?.fileURL); XCTAssertTrue(library.files.isAppCopy(managed))
        try FileManager.default.removeItem(at: managed)
        // Removing a card must not need a file it can no longer protect.
        try library.removeFromShelf([record.id])
        XCTAssertEqual(try library.item(record.id)?.onShelf, false); XCTAssertNil(try library.item(record.id)?.deletedAt)
        try library.trash([record.id])
        XCTAssertNotNil(try library.item(record.id)?.deletedAt)
        try library.restore([record.id])
        let restored = try XCTUnwrap(library.item(record.id)); XCTAssertNil(restored.deletedAt); XCTAssertTrue(restored.onShelf)
        // Pinning still refuses a file that cannot be copied.
        let external = try library.captureImage(try f.image(owned: false)); try FileManager.default.removeItem(at: try XCTUnwrap(external.fileURL))
        XCTAssertThrowsError(try library.toggleFavorite([external.id]))
    }
    func testMovingFromParentRemovesChildMembershipButKeepsOtherFoldersAndOriginal() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let url = try f.image(owned: false), bytes = try Data(contentsOf: url), record = try library.captureImage(url)
        let parent = try library.createCollection("Parent"), child = try library.createCollection("Child", parent: parent)
        let other = try library.createCollection("Other"), target = try library.createCollection("Target")
        try library.assign([record.id], to: child); try library.assign([record.id], to: other)
        try library.assign([record.id], to: target, movingFrom: parent)
        XCTAssertEqual(Set(try library.collections(for: record.id).map(\.id)), Set([other,target]))
        XCTAssertTrue(try library.query(LibraryQuery(scope: .collection(parent))).isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDomainFilterIncludesSubdomainsWithLiteralHostBoundaries() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let expected = try ["https://youtube.com/one", "https://www.youtube.com/two", "https://m.youtube.com/three"].map { try library.captureLink(URL(string: $0)!).id }
        _ = try library.captureLink(URL(string: "https://notyoutube.com/four")!)
        _ = try library.captureLink(URL(string: "https://youtube.com.example.com/five")!)
        XCTAssertEqual(Set(try library.query(LibraryQuery(scope: .recent, domain: "YouTube.com")).map(\.id)), Set(expected))
        XCTAssertEqual(try library.query(LibraryQuery(scope: .recent, domain: "WWW.YouTube.com.")).count, 3)
        XCTAssertTrue(try library.query(LibraryQuery(scope: .recent, domain: "%youtube.com")).isEmpty)
    }
    func testBlankOrPaddedItemNameIsIgnoredOrTrimmedLikeWindows() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let plan = try XCTUnwrap(library.captureText("Quarterly plan\nsecond line")), other = try XCTUnwrap(library.captureText("Middle"))
        try library.retain([plan.id, other.id])
        try library.update(plan.id) { $0.title = "   " }
        XCTAssertEqual(try library.item(plan.id)?.displayTitle, "Quarterly plan")
        try library.update(plan.id) { $0.title = "  Zulu \n" }
        XCTAssertEqual(try library.item(plan.id)?.displayTitle, "Zulu")
        XCTAssertEqual(try library.query(LibraryQuery(scope: .saved, sort: .title)).map(\.id), [other.id, plan.id])
    }
    func testTagRenameSearchTurkishAndLiteralSQLCharacters() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try XCTUnwrap(library.captureText("İLK çekim 中文 👋"))
        try library.addTag("İŞ", to: [record.id]); try library.addTag("iş", to: [record.id])
        XCTAssertEqual(try library.tags().count, 1)
        XCTAssertEqual(try library.query(LibraryQuery(search: "ilk 中文")).first?.id, record.id)
        let tag = try XCTUnwrap(library.tags().first); try library.renameTag(tag.id, name: "'); DROP TABLE items; --")
        XCTAssertEqual(try library.query(LibraryQuery(search: "DROP TABLE")).count, 1)
        try library.removeTag(tag.id); XCTAssertTrue(try library.query(LibraryQuery(search: "DROP TABLE")).isEmpty)
        XCTAssertEqual(try library.item(record.id)?.text, "İLK çekim 中文 👋")
    }
    func testTrashRestoresContentAndRelationshipsWithoutMovingOriginal() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let original = try f.image(owned: false), record = try library.captureImage(original), folder = try library.createCollection("Folder")
        try library.assign([record.id], to: folder); try library.addTag("tag", to: [record.id]); try library.trash([record.id])
        XCTAssertTrue(try library.query(LibraryQuery()).isEmpty)
        XCTAssertEqual(try library.query(LibraryQuery(scope: .trash)).first?.id, record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try library.restore([record.id]); XCTAssertEqual(try library.collections(for: record.id).map(\.id), [folder]); XCTAssertEqual(try library.tags(for: record.id).count, 1)
        try library.removeFromShelf([record.id]); XCTAssertTrue(try library.shelfItems(.image).isEmpty); XCTAssertEqual(try library.query(LibraryQuery()).first?.id, record.id)
    }
    func testAdaptersShareStableIdentityTextEditsFavoritesAndRestart() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in }, copyText: { _ in }, library: library)
        let id = try XCTUnwrap(line.hang(try f.image(), quietly: true)); XCTAssertEqual(line.items[0].id, id)
        XCTAssertTrue(line.texts.add("first")); let textID = line.texts.entries[0].id
        let cache = try line.texts.materialize(line.texts.entries[0])
        try library.update(textID) { $0.text = "edited 👋" }
        XCTAssertEqual(line.texts.entries[0].text, "edited 👋"); XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "edited 👋")
        try library.toggleFavorite([id,textID]); XCTAssertTrue(line.items[0].pinned); XCTAssertTrue(line.texts.entries[0].pinned)
        let restarted = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: try store(f))
        XCTAssertEqual(restarted.items[0].id, id); XCTAssertEqual(restarted.texts.entries[0].id, textID)
        line.discard(id, quietly: true); XCTAssertTrue(line.items.isEmpty); XCTAssertTrue(try library.item(id)?.retainedAt != nil)
    }
    func testInvalidBatchRollsBackInsteadOfPartiallyAssigningOrRetaining() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try XCTUnwrap(library.captureText("note")), folder = try library.createCollection("Folder")
        var failed = false; do { try library.assign([record.id,UUID()], to: folder) } catch { failed = true }
        XCTAssertTrue(failed); XCTAssertNil(try library.item(record.id)?.retainedAt); XCTAssertTrue(try library.collections(for: record.id).isEmpty)
    }
    func testSnapshotIncludesWALCommittedChangesAndIsPrivate() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let record = try XCTUnwrap(library.captureText("latest committed")); try library.retain([record.id])
        let snapshot = f.folder.appendingPathComponent("snapshot.sqlite")
        try library.backup(to: snapshot)
        let db = try LibraryDatabase(url: snapshot, readOnly: true)
        XCTAssertEqual(try db.rows("SELECT count(*) AS n FROM items").first?["n"]?.number, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testLinkIdentityPreservesMeaningfulParametersAndDeduplicatesVideoForms() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let a = try library.captureLink(try XCTUnwrap(URL(string: "https://youtu.be/jNQXAC9IVRw?t=10&utm_source=share")))
        let b = try library.captureLink(try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw&t=10")))
        XCTAssertEqual(a.id, b.id); XCTAssertEqual(b.originalURL, a.originalURL)
        let differentTime = try library.captureLink(try XCTUnwrap(URL(string: "https://www.youtube.com/shorts/jNQXAC9IVRw?t=20")))
        XCTAssertTrue(differentTime.id != a.id)
        XCTAssertNil(LinkIdentity.standalone("a paragraph https://example.com")); XCTAssertNil(LinkIdentity.standalone("https://one.com https://two.com"))
        XCTAssertNil(LinkIdentity.standalone("file:///private/test")); XCTAssertNil(LinkIdentity.standalone("javascript:alert(1)"))
        XCTAssertNil(LinkIdentity.standalone("https://example.com:99999/")); XCTAssertNotNil(LinkIdentity.standalone("https://example.com:65535/"))
        for credentialed in ["https://user:" + "pass@example.com/a", "https://user@example.com/a", "https://:pass@example.com/a"] { XCTAssertNil(LinkIdentity.standalone(credentialed), credentialed) }
        for plain in ["https://example.com/a", "https://example.com/a@b"] { XCTAssertNotNil(LinkIdentity.standalone(plain), plain) }
        XCTAssertFalse(LinkIdentity.mayFetchMetadata(try XCTUnwrap(URL(string: "http://192.168.1.2/doc"))))
        XCTAssertFalse(LinkIdentity.mayFetchMetadata(try XCTUnwrap(URL(string: "https://example.com/?token=private"))))
        XCTAssertTrue(LinkIdentity.mayFetchMetadata(try XCTUnwrap(URL(string: "https://example.com/articles"))))
    }
    func testPagingAndBackgroundQueriesRespectScopeAndResultOrder() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        for i in 0..<120 { let item = try XCTUnwrap(library.captureText("note \(i)")); try library.retain([item.id]) }
        let first = try library.query(LibraryQuery(), limit: 40), second = try library.query(LibraryQuery(), limit: 40, offset: 40)
        XCTAssertEqual(first.first?.text, "note 119"); XCTAssertEqual(second.first?.text, "note 79")
        var result: [LibraryRecord]?
        library.queryAsync(LibraryQuery(search: "note 119")) { if case let .success(values) = $0 { result = values } }
        let deadline = Date().addingTimeInterval(3)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(result?.first?.id, first.first?.id)
    }
    func testRecapturedLinkMovesLeftAndRenewsTemporaryCaptureWithoutResettingOriginalDate() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let first = try library.captureLink(URL(string: "https://example.com/first")!)
        f.date.addTimeInterval(1); let second = try library.captureLink(URL(string: "https://example.com/second")!)
        f.date.addTimeInterval(31 * 86400); let recaptured = try library.captureLink(first.linkURL!)
        XCTAssertEqual(recaptured.id, first.id); XCTAssertEqual(recaptured.createdAt, first.createdAt)
        XCTAssertEqual(try library.shelfItems(.link).first?.id, first.id)
        try library.prune(); XCTAssertNil(try library.item(first.id)?.deletedAt); XCTAssertTrue(try library.item(second.id)?.deletedAt != nil)
        f.date.addTimeInterval(31 * 86400); try library.prune(); XCTAssertTrue(try library.item(first.id)?.deletedAt != nil)
    }
    func testRestoringOldCopyAfterRecapturePreservesBothRecordsAndPinsExactImageID() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let library = try store(f)
        let original = try f.image(owned: false), first = try library.captureImage(original), link = try library.captureLink(URL(string: "https://example.com/repeated")!)
        try library.update(first.id) { $0.note = "old note" }; try library.trash([first.id,link.id])
        f.date.addTimeInterval(1); let second = try library.captureImage(original), secondLink = try library.captureLink(link.linkURL!)
        try library.restore([first.id,link.id]); XCTAssertEqual(try library.shelfItems(.image).count, 2); XCTAssertEqual(try library.shelfItems(.link).count, 2)
        XCTAssertTrue(first.id != second.id); XCTAssertTrue(link.id != secondLink.id); XCTAssertEqual(try library.item(first.id)?.note, "old note")
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: library)
        line.pinFromUI(first.id); XCTAssertTrue(try library.item(first.id)?.favorite == true); XCTAssertFalse(try library.item(second.id)?.favorite == true)
    }
}
