import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShelfSearchTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Background shelf search did not complete")
    }
    private func matches(_ store: LibraryStore, _ kind: LibraryKind, _ query: String, favoritesOnly: Bool = false) throws -> Set<UUID> {
        var result: Result<[UUID], Error>?
        store.shelfMatchingIDsAsync(kind: kind, search: query, favoritesOnly: favoritesOnly) { result = $0 }
        wait { result != nil }
        return Set(try XCTUnwrap(result).get())
    }
    private func indexOCR(_ text: String, item: LibraryRecord, store: LibraryStore, path: String? = nil) throws {
        let db = try LibraryDatabase(url: store.databaseURL, verify: false)
        try db.execute("INSERT INTO image_analysis(item,path,fingerprint,version,content,ocr,vectors) VALUES(?,?,?,?,?,?,?) ON CONFLICT(item) DO UPDATE SET path=excluded.path,content=excluded.content,ocr=excluded.ocr", [
            .text(item.id.uuidString), .text(try XCTUnwrap(path ?? item.path)), .text("synthetic"), .text("vision-ocr-v1"), .text(text.searchFolded), .text(text), .blob(Data())
        ])
    }
    func testShelfSearchScopesTemporaryAndSavedMatchesToCurrentKindMembershipAndPins() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        let temporary = try XCTUnwrap(store.captureText("shared temporary")), saved = try XCTUnwrap(store.captureText("shared saved"))
        let hidden = try XCTUnwrap(store.captureText("shared hidden")), deleted = try XCTUnwrap(store.captureText("shared deleted"))
        let link = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/shared")))
        try store.toggleFavorite([saved.id, hidden.id]); try store.removeFromShelf([hidden.id]); try store.trash([deleted.id])
        XCTAssertEqual(try matches(store, .text, "shared"), Set([temporary.id, saved.id]))
        XCTAssertEqual(try matches(store, .text, "shared", favoritesOnly: true), Set([saved.id]))
        XCTAssertEqual(try matches(store, .link, "shared"), Set([link.id]))
        XCTAssertTrue(try matches(store, .image, "shared").isEmpty)
        XCTAssertTrue(try store.item(hidden.id)?.retainedAt != nil)
        XCTAssertTrue(try store.item(deleted.id)?.deletedAt != nil)
    }
    func testShelfSearchUsesTitlesTextNotesURLsTagsAndCurrentImageOCRWithLiteralUnicodeTerms() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let note = try XCTUnwrap(store.captureText("İSTANBUL body 中文"))
        try store.update(note.id) { $0.title = "Planning headline"; $0.note = "private-notes 42%_" }
        try store.addTag("KAMERA", to: [note.id])
        let link = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/watch?topic=orbital")))
        try store.update(link.id) { $0.metadataTitle = "Orbital episode"; $0.note = "reference" }
        let image = try store.captureImage(f.image()), wrongPath = try store.captureImage(f.image())
        try indexOCR("İSTANBUL ORBITAL 8427", item: image, store: store)
        try indexOCR("ORBITAL 8427", item: wrongPath, store: store, path: "/synthetic/stale-path.png")
        XCTAssertEqual(try matches(store, .text, "istanbul 中文"), Set([note.id]))
        XCTAssertEqual(try matches(store, .text, "headline kamera private-notes"), Set([note.id]))
        XCTAssertEqual(try matches(store, .text, "42%_"), Set([note.id]))
        XCTAssertTrue(try matches(store, .text, "'; DROP TABLE items; --").isEmpty)
        XCTAssertEqual(try matches(store, .link, "episode example.com orbital reference"), Set([link.id]))
        XCTAssertEqual(try matches(store, .image, "istanbul 8427"), Set([image.id]))
        XCTAssertEqual(try matches(store, .image, "orbital"), Set([image.id]), "OCR for a previous path must not match")
        XCTAssertEqual(try store.item(note.id)?.text, "İSTANBUL body 中文")
        XCTAssertTrue(try store.item(image.id)?.retainedAt == nil, "Searching must not retain or pin records")
    }
    func testShelfSearchModelDebouncesLatestQueryKeepsKindsIndependentAndDropsClosedResults() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        _ = try store.captureText("alpha only"); let beta = try XCTUnwrap(store.captureText("beta only"))
        let link = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/alpha")))
        let model = ShelfSearchModel(store: store, debounce: 0.04)
        model.update("alpha", for: .text); model.update("beta", for: .text); model.update("alpha", for: .link)
        XCTAssertEqual(model.matchingIDs(for: .text), [])
        wait { !model.isSearching(for: .text) && !model.isSearching(for: .link) }
        XCTAssertEqual(model.query(for: .text), "beta"); XCTAssertEqual(model.matchingIDs(for: .text), Set([beta.id]))
        XCTAssertEqual(model.matchingIDs(for: .link), Set([link.id])); XCTAssertNil(model.matchingIDs(for: .image))
        model.update("never completes into the closed row", for: .text); model.close(.text)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.isActive(for: .text)); XCTAssertEqual(model.query(for: .text), ""); XCTAssertNil(model.matchingIDs(for: .text))
        XCTAssertEqual(model.matchingIDs(for: .link), Set([link.id]))
        model.clear(.link); XCTAssertTrue(model.isActive(for: .link)); XCTAssertNil(model.matchingIDs(for: .link))
        model.update("alpha", for: .link); model.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.states.isEmpty); XCTAssertNil(model.matchingIDs(for: .link))
    }
    func testShelfSearchRefreshesOpenQueriesAfterEditsPinsMembershipAndOCRIndexChanges() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }), model = ShelfSearchModel(store: store, debounce: 0)
        let text = try XCTUnwrap(store.captureText("original")), image = try store.captureImage(f.image())
        model.update("newterm", for: .text); model.update("8427", for: .image)
        wait { !model.isSearching(for: .text) && !model.isSearching(for: .image) }
        XCTAssertEqual(model.matchingIDs(for: .text), []); XCTAssertEqual(model.matchingIDs(for: .image), [])
        try store.update(text.id) { $0.text = "newterm" }
        wait { !model.isSearching(for: .text) && model.matchingIDs(for: .text) == Set([text.id]) }
        model.setFavoritesOnly(true, for: .text)
        wait { !model.isSearching(for: .text) }; XCTAssertEqual(model.matchingIDs(for: .text), [])
        try store.toggleFavorite([text.id])
        wait { !model.isSearching(for: .text) && model.matchingIDs(for: .text) == Set([text.id]) }
        try store.removeFromShelf([text.id])
        wait { !model.isSearching(for: .text) && model.matchingIDs(for: .text)?.isEmpty == true }
        try indexOCR("ORBITAL 8427", item: image, store: store); store.imageSearchChanged()
        wait { !model.isSearching(for: .image) && model.matchingIDs(for: .image) == Set([image.id]) }
        model.update("  \n ", for: .image); XCTAssertNil(model.matchingIDs(for: .image)); XCTAssertFalse(model.isSearching(for: .image))
        model.close()
    }
}
