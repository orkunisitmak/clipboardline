import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor private final class LibraryClipboard: ClipboardSource {
    var count = 31000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var reads = 0
    var duringRead: (() -> Void)?
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType: NSPasteboard.PasteboardType, at index: Int) -> Data? { reads += 1; let value = values[index][forType]; duringRead?(); return value }
    func copy(_ text: String) { count += 1; values = [[.string: Data(text.utf8)]] }
}

@MainActor final class LibraryInteractionTests: HistoryTestCase {
    private func library(_ f: SyntheticFixture) throws -> LibraryStore { try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder)) }
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate())
    }
    private func key(_ code: UInt16, _ character: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    func testPagedTagSummariesRefreshAfterRenameAndRemovalWithoutChangingSelection() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let plain = try XCTUnwrap(store.captureText("plain note")), tagged = try XCTUnwrap(store.captureText("tagged note İstanbul 中文"))
        try store.retain([plain.id, tagged.id])
        for name in ["中文", "Zeta", "İstanbul"] { try store.addTag(name, to: [tagged.id]) }
        let model = LibraryModel(store: store)
        wait { model.cardSummary(tagged.id) != nil && model.cardSummary(plain.id) != nil }
        XCTAssertEqual(model.cardSummary(tagged.id)?.tagNames, ["İstanbul", "Zeta"])
        XCTAssertEqual(model.cardSummary(tagged.id)?.tagCount, 3)
        XCTAssertEqual(model.cardSummary(tagged.id)?.tagLabel, "#İstanbul · #Zeta · +1")
        XCTAssertEqual(model.cardSummary(plain.id)?.tagLabel, "")
        _ = model.select(tagged.id)
        let zeta = try XCTUnwrap(store.tags().first { $0.name == "Zeta" })
        try store.renameTag(zeta.id, name: "Alpha")
        wait { model.cardSummary(tagged.id)?.tagNames == ["Alpha", "İstanbul"] }
        XCTAssertEqual(model.selectedIDs, [tagged.id]); XCTAssertEqual(model.focusedID, tagged.id)
        try store.removeTag(zeta.id, from: tagged.id)
        wait { model.cardSummary(tagged.id)?.tagCount == 2 }
        XCTAssertEqual(model.cardSummary(tagged.id)?.tagLabel, "#İstanbul · #中文")
        XCTAssertEqual(model.selectedIDs, [tagged.id])
        XCTAssertEqual(try store.item(tagged.id)?.text, tagged.text)
    }
    func testPinningAMixedLibrarySelectionPinsEveryItemAndOnlyAFullyPinnedSelectionUnpins() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let ids = try (0..<3).map { index -> UUID in let record = try XCTUnwrap(store.captureText("pin note \(index)")); try store.retain([record.id]); return record.id }
        try store.toggleFavorite([ids[0]])
        let retainedAt = try store.records(ids).map(\.retainedAt)
        f.date = f.date.addingTimeInterval(1)
        let model = LibraryModel(store: store)
        wait { model.ids.count == 3 && !model.loading }
        model.selectAll(); model.favorite()
        XCTAssertEqual(try store.records(ids).map(\.favorite), [true, true, true])
        XCTAssertEqual(try store.records(ids).map(\.retainedAt), retainedAt)
        f.date = f.date.addingTimeInterval(1)
        model.favorite()
        XCTAssertEqual(try store.records(ids).map(\.favorite), [false, false, false])
        XCTAssertEqual(try store.records(ids).map(\.retainedAt), retainedAt)
    }
    func testRemovingATagAlsoDropsItsLibraryFilterSoItemsStayVisible() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let note = try XCTUnwrap(store.captureText("tagged note")); try store.retain([note.id]); try store.addTag("Work", to: [note.id])
        let tag = try XCTUnwrap(store.tags().first)
        let model = LibraryModel(store: store)
        wait { model.ids == [note.id] && !model.loading }
        model.toggleTagFilter(tag.id); wait { model.query.tagIDs == [tag.id] && !model.loading }
        XCTAssertEqual(model.ids, [note.id])
        try store.removeTag(tag.id)
        wait { model.query.tagIDs.isEmpty && !model.loading }
        XCTAssertEqual(model.ids, [note.id])
    }
    func testTextCopiedWithWindowsLineEndingsIsTitledByItsFirstLine() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let note = try XCTUnwrap(store.captureText("Shopping list\r\nmilk\r\nbread"))
        XCTAssertEqual(note.displayTitle, "Shopping list")
    }
    func testNativeSearchEscapeRoutesImmediateSelectAllToCollectionAndLeavesOtherEditorsAlone() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        for text in ["first note", "second note"] { let record = try XCTUnwrap(store.captureText(text)); try store.retain([record.id]) }
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store)
        let controller = LibraryWindowController(store: store, line: line)
        let window = try XCTUnwrap(controller.window), model = controller.model
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let search = LibrarySearchTextField(model: model), other = NSTextField(string: "another editor"), collection = NSCollectionView()
        search.frame = NSRect(x: 10, y: 150, width: 300, height: 24); other.frame = NSRect(x: 10, y: 110, width: 300, height: 24)
        content.addSubview(search); content.addSubview(other); content.addSubview(collection); window.contentView = content
        model.onContentFocus = { window.makeFirstResponder(collection) }
        wait { model.ids.count == 2 }
        model.onSearchFocus?()
        XCTAssertTrue(window.firstResponder === search || window.firstResponder === search.currentEditor())
        XCTAssertTrue(window.performKeyEquivalent(with: key(53)))
        XCTAssertTrue(window.firstResponder === collection)
        XCTAssertTrue(window.performKeyEquivalent(with: key(0, "a", [.command])))
        XCTAssertEqual(model.selectedIDs, Set(model.ids))
        window.makeFirstResponder(other); other.selectText(nil)
        XCTAssertFalse(model.onSearchEscape?() ?? true)
        XCTAssertTrue(window.firstResponder === other || window.firstResponder === other.currentEditor())
        window.contentView = nil; controller.close()
    }
    func testRouterMakesOneDecisionAndPreservesParagraphsAndIndependentSources() throws {
        let source = LibraryClipboard(); var texts = [String](), links = [URL](), textOn = true, linkOn = true
        let watcher = TextClipboardWatcher(source: source, onText: { texts.append($0) }, onLink: { links.append($0) }, capturesText: { textOn }, capturesLinks: { linkOn })
        defer { watcher.stop() }; watcher.start()
        source.copy(" https://youtu.be/jNQXAC9IVRw\n"); watcher.check()
        source.copy("some text https://example.com"); watcher.check()
        source.copy("https://one.com https://two.com"); watcher.check()
        XCTAssertEqual(links.count, 1); XCTAssertEqual(texts.count, 2)
        textOn = false; source.copy("ordinary text"); watcher.check(); XCTAssertEqual(texts.count, 2)
        source.copy("https://example.com/new"); watcher.check(); XCTAssertEqual(links.count, 2)
        linkOn = false; textOn = true; source.copy("https://example.com/another"); watcher.check(); XCTAssertEqual(texts.last, "https://example.com/another")
        linkOn = true; source.count += 1; source.values = [[.URL: Data("https://example.com/url-representation".utf8)]]; watcher.check(); XCTAssertEqual(links.last?.path, "/url-representation")
    }
    func testRouterSkipsPrivateMarkersFilesImagesOwnCopyAndRacesBeforeRecording() throws {
        let source = LibraryClipboard(); var received = 0
        let watcher = TextClipboardWatcher(source: source, onText: { _ in received += 1 }, onLink: { _ in received += 1 }, capturesLinks: { true })
        defer { watcher.stop() }; watcher.start()
        for marker in ClipboardWatcher.privateTypes.union([.fileURL, .png]) {
            source.copy("https://example.com/private"); source.values.append([marker: Data()]); let reads = source.reads; watcher.check(); XCTAssertEqual(source.reads, reads)
        }
        source.copy("https://example.com/own"); ClipboardWatcher.recordOwnCopy(changeCount: source.count); let reads = source.reads; watcher.check(); XCTAssertEqual(source.reads, reads)
        source.copy("https://example.com/raced"); source.duringRead = { source.count += 1 }; watcher.check(); XCTAssertEqual(received, 0)
        source.duringRead = nil; watcher.skipCurrent(); watcher.check(); XCTAssertEqual(received, 0)
    }
    func testTextCaptureDoesNotRevealSwitchShelvesOrRequestFocusInAnyPresentation() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store)
        let app = AppDelegate(line: line, watchesFiles: false); var focus = 0; line.onFocusRequested = { focus += 1 }
        for (i, mode) in ShelfPresentation.allCases.enumerated() {
            line.setPresentation(mode, requestFocus: false); let active = line.activeShelf
            line.revealed = false; app.receiveCopiedText("silent capture \(i)")
            XCTAssertFalse(line.revealed); XCTAssertEqual(line.activeShelf, active); XCTAssertEqual(line.presentation, mode)
            line.revealed = true; app.receiveCopiedText("visible update \(i)"); XCTAssertTrue(line.revealed)
        }
        XCTAssertEqual(focus, 0); XCTAssertEqual(line.texts.entries.count, ShelfPresentation.allCases.count * 2)
    }
    func testThreeShelvesPersistCycleAndUseIndependentKeyboardSelectionAndPreview() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, copyText: { _ in }, library: store)
        line.hang(try f.image(), quietly: true); line.texts.add("text")
        let first = try XCTUnwrap(line.links.add(URL(string: "https://example.com/a")!)), second = try XCTUnwrap(line.links.add(URL(string: "https://example.com/b")!))
        line.setPresentation(.all, requestFocus: false); line.setViewportWidth(250)
        line.switchShelf(); XCTAssertEqual(line.activeShelf, .texts); line.switchShelf(); XCTAssertEqual(line.activeShelf, .links)
        var preview: UUID?, images = 0
        let keyboard = LineKeyboard(line: line, onCopy: { _ in images += 1 }, onPreview: { _ in images += 1 }, onClose: {}, onLinkPreview: { preview = $0 })
        _ = keyboard.handle(key(124)); _ = keyboard.handle(key(124, "", [.shift])); _ = keyboard.handle(key(36)); _ = keyboard.handle(key(49))
        XCTAssertEqual(line.links.selectedIDs, Set([first.id,second.id])); XCTAssertEqual(preview, first.id); XCTAssertEqual(images, 0)
        _ = keyboard.handle(key(35, "p", [.command])); XCTAssertTrue(line.links.entries.allSatisfy(\.favorite))
        XCTAssertEqual(line.items.count, 1); XCTAssertFalse(line.items[0].pinned); XCTAssertEqual(line.texts.entries.count, 1)
        let restarted = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: try library(f)); XCTAssertEqual(restarted.presentation, .all); XCTAssertEqual(restarted.links.entries.map(\.id), line.links.entries.map(\.id))
    }
    func testLibraryKeyboardGridRangesAllResultsFiltersAndEditingStayDistinct() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        var records = [LibraryRecord]()
        for i in 0..<150 { var record = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date.addingTimeInterval(Double(i)), updatedAt: f.date); record.text = "entry \(i)"; record.retainedAt = f.date; record.onShelf = false; records.append(record) }
        try store.importRecords(records); let model = LibraryModel(store: store); wait { model.ids.count == 150 }
        model.columns = 4
        _ = model.handleKey(key(125), editing: false); XCTAssertEqual(model.focusedID, records[149].id)
        _ = model.handleKey(key(125, "", [.shift]), editing: false); XCTAssertEqual(model.focusedID, records[145].id); XCTAssertEqual(model.selectedIDs.count, 5)
        _ = model.handleKey(key(0, "a", [.command]), editing: false); XCTAssertEqual(model.selectedIDs.count, 150)
        let before = model.focusedID; XCTAssertFalse(model.handleKey(key(123), editing: true)); XCTAssertFalse(model.handleKey(key(8, "c", [.command]), editing: true)); XCTAssertEqual(model.focusedID, before)
        var searchFocused = true, contentFocusRequests = 0
        model.onContentFocus = { contentFocusRequests += 1 }
        model.onSearchEscape = {
            guard searchFocused else { return false }
            searchFocused = false; model.onContentFocus?(); return true
        }
        XCTAssertTrue(model.handleKey(key(53), editing: true))
        XCTAssertFalse(searchFocused); XCTAssertEqual(contentFocusRequests, 1)
        XCTAssertEqual(model.focusedID, before); XCTAssertEqual(model.selectedIDs.count, 150)
        XCTAssertFalse(model.handleKey(key(53), editing: false))
        XCTAssertFalse(model.handleKey(key(53), editing: true))
        XCTAssertEqual(contentFocusRequests, 1)
        _ = model.handleKey(key(20, "3", [.command]), editing: false); wait { !model.loading }; XCTAssertTrue(model.ids.isEmpty)
        _ = model.handleKey(key(29, "0", [.command]), editing: false); wait { model.ids.count == 150 }
    }
    func testRapidQueriesCannotOverwriteLatestSearchAndRetainFocusOnMetadataChange() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let a = try XCTUnwrap(store.captureText("alpha")), b = try XCTUnwrap(store.captureText("beta")); try store.retain([a.id,b.id])
        let model = LibraryModel(store: store); wait { model.ids.count == 2 }; _ = model.select(a.id)
        try store.update(a.id) { $0.note = "metadata note" }; wait { !model.loading }; XCTAssertEqual(model.focusedID, a.id); XCTAssertEqual(model.selectedIDs, [a.id])
        model.search = "alpha"; model.search = "beta"; wait { model.ids == [b.id] }
    }
    func testRemovingLastVisibleItemClearsInspectorAndFiltersRecoverSameScope() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let record = try XCTUnwrap(store.captureText("filtered note")); try store.toggleFavorite([record.id])
        let folder = try store.createCollection("Notes"); try store.assign([record.id], to: folder)
        let model = LibraryModel(store: store); model.changeScope(.collection(folder)); model.setKind(.text); model.setFavorites(true)
        wait { model.ids == [record.id] }; _ = model.select(record.id); model.favorite()
        wait { model.ids.isEmpty && !model.loading }
        XCTAssertNil(model.focusedID); XCTAssertNil(model.inspected); XCTAssertTrue(model.draftText.isEmpty)
        XCTAssertTrue(model.query.hasFilters); model.clearFilters(); wait { model.ids == [record.id] }
        XCTAssertEqual(model.query.scope, .collection(folder)); XCTAssertFalse(model.query.hasFilters)
        _ = model.select(record.id); model.trash(); wait { model.ids.isEmpty && !model.loading }
        XCTAssertNil(model.inspected); XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    func testSubfolderTitleIncludesItsParentLikeWindows() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let parent = try store.createCollection("Parent"), middle = try store.createCollection("Middle", parent: parent)
        let child = UUID()  // createCollection allows two levels only, so insert the third level (e.g. from imported data) directly
        try LibraryDatabase(url: store.databaseURL).execute("INSERT INTO collections VALUES(?,?,?,?)", [.text(child.uuidString), .text("Child"), .text(middle.uuidString), .text("Child".libraryFolded)])
        let model = LibraryModel(store: store)
        wait { model.collections.count == 3 && !model.loading }
        model.changeScope(.collection(parent)); wait { model.query.scope == .collection(parent) && !model.loading }
        XCTAssertEqual(model.title, "Parent")
        model.changeScope(.collection(child)); wait { model.query.scope == .collection(child) && !model.loading }
        XCTAssertEqual(model.title, "Parent / Middle / Child")
        model.changeScope(.collection(middle)); wait { model.query.scope == .collection(middle) && !model.loading }
        XCTAssertEqual(model.title, "Parent / Middle")
    }
    func testUnnamedItemTitlesAreTheTrimmedFirstLineAndLinkHostLikeWindows() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let indented = try XCTUnwrap(store.captureText("\t  Indented first line \nsecond line")), long = try XCTUnwrap(store.captureText(String(repeating: "x", count: 130)))
        let link = try store.captureLink(URL(string: "https://www.example.com/a/very/long/path?utm_source=news")!)
        XCTAssertEqual(indented.displayTitle, "Indented first line"); XCTAssertEqual(long.displayTitle, String(repeating: "x", count: 120)); XCTAssertEqual(link.displayTitle, "www.example.com")
        let blankFirst = try XCTUnwrap(store.captureText("\n \t\nSecond line\nthird"))
        XCTAssertEqual(blankFirst.displayTitle, "Second line")
        let blank = try XCTUnwrap(store.captureText(" \t")); XCTAssertEqual(blank.displayTitle, L("Untitled note"))
        try store.update(link.id) { $0.originalURL = "http://[bad" }; XCTAssertEqual(try XCTUnwrap(store.item(link.id)).displayTitle, L("Link"))
    }
    func testRemovingAnotherFolderKeepsTheOpenViewLikeWindows() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let keep = try store.createCollection("Keep"), other = try store.createCollection("Other")
        let parent = try store.createCollection("Parent"), child = try store.createCollection("Child", parent: parent)
        let first = try XCTUnwrap(store.captureText("first kept note")), second = try XCTUnwrap(store.captureText("second kept note")); try store.assign([first.id, second.id], to: keep)
        let model = LibraryModel(store: store)
        wait { model.collections.count == 4 && !model.loading }
        model.changeScope(.collection(keep)); wait { model.query.scope == .collection(keep) && model.ids.count == 2 && !model.loading }
        let chosen = model.ids[1]; _ = model.select(chosen)
        model.removeFolder(other); wait { model.collections.count == 3 && !model.loading }
        XCTAssertEqual(model.query.scope, .collection(keep))
        XCTAssertEqual(model.selectedIDs, [chosen]); XCTAssertEqual(model.focusedID, chosen)
        model.changeScope(.collection(child)); wait { model.query.scope == .collection(child) && !model.loading }
        model.removeFolder(parent); wait { model.collections.count == 1 && model.query.scope == .saved && !model.loading }
        model.changeScope(.collection(keep)); wait { model.query.scope == .collection(keep) && !model.loading }
        model.removeFolder(keep); wait { model.collections.isEmpty && model.query.scope == .saved && !model.loading }
    }
    func testRestoringFromTrashSelectsTheFirstRemainingItemLikeWindows() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let records = try ["first trashed note", "second trashed note", "third trashed note"].map { try XCTUnwrap(store.captureText($0)) }
        try store.trash(records.map(\.id))
        let model = LibraryModel(store: store); model.changeScope(.trash)
        wait { model.ids.count == 3 && !model.loading }
        let order = model.ids
        _ = model.select(order[1]); model.restore()
        wait { model.ids.count == 2 && !model.loading }
        XCTAssertEqual(model.ids, [order[0], order[2]])
        XCTAssertEqual(model.focusedID, order[0]); XCTAssertEqual(model.selectedIDs, [order[0]]); XCTAssertEqual(model.inspected?.id, order[0])
        model.restore()
        wait { model.ids.count == 1 && !model.loading }
        XCTAssertEqual(model.focusedID, order[2]); XCTAssertEqual(model.selectedIDs, [order[2]])
        model.restore()
        wait { model.ids.isEmpty && !model.loading }
        XCTAssertNil(model.focusedID); XCTAssertNil(model.inspected); XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    func testInspectorEditsPersistAndFailedSaveKeepsDraftAndSelection() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let a = try XCTUnwrap(store.captureText("first")), b = try XCTUnwrap(store.captureText("second")); try store.retain([a.id,b.id])
        let model = LibraryModel(store: store); wait { model.ids.count == 2 }; _ = model.select(a.id)
        model.draftTitle = "title"; model.draftText = "edited 👋"; model.draftNote = "private note"; XCTAssertTrue(model.flushEdits())
        XCTAssertEqual(try store.item(a.id)?.text, "edited 👋"); XCTAssertEqual(try store.item(a.id)?.note, "private note")
        let folder = try store.createCollection("Drafts"); try store.assign([a.id], to: folder); try store.addTag("draft", to: [a.id])
        let tag = try XCTUnwrap(store.tags().first); wait { !model.loading }
        model.draftText = String(repeating: "x", count: TextClipboardWatcher.maximumDataBytes + 1)
        XCTAssertFalse(model.flushEdits()); XCTAssertFalse(model.select(b.id)); XCTAssertEqual(model.focusedID, a.id)
        let query = model.query
        model.setDays(7); model.setDomain("example.com"); model.toggleTagFilter(tag.id); model.clearFilters()
        model.unassign(folder); model.removeTag(tag.id); model.search = "second"
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(model.query, query); XCTAssertEqual(model.focusedID, a.id); XCTAssertEqual(model.selectedIDs, [a.id])
        XCTAssertEqual(try store.collections(for: a.id).map(\.id), [folder]); XCTAssertEqual(try store.tags(for: a.id).map(\.id), [tag.id])
        XCTAssertEqual(try store.item(a.id)?.text, "edited 👋"); model.draftText = "fixed"; XCTAssertTrue(model.flushEdits()); XCTAssertTrue(model.select(b.id))
    }
    func testMixedTransferExportAndDragPreserveRepresentationsOrderAndOriginals() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let imageURL = try f.image(owned: false), image = try store.captureImage(imageURL), text = try XCTUnwrap(store.captureText("synthetic note")), link = try store.captureLink(URL(string: "https://example.com/path?t=10")!)
        let values = [image,text,link], before = try Data(contentsOf: imageURL)
        let items = try LibraryTransfer.pasteboardItems(values)
        XCTAssertEqual(items.count, 3); XCTAssertTrue(items[0].types.contains(.png)); XCTAssertEqual(items[1].string(forType: .string), "synthetic note"); XCTAssertEqual(items[2].string(forType: .URL), link.originalURL)
        let sources = try LibraryTransfer.exportSources(values, store: store); XCTAssertEqual(sources.map { $0.url.pathExtension }, ["png","txt","webloc"])
        let web = try PropertyListSerialization.propertyList(from: Data(contentsOf: sources[2].url), format: nil) as? [String:String]; XCTAssertEqual(web?["URL"], link.originalURL)
        let drag = try LibraryTransfer.dragItems(values, store: store); XCTAssertEqual(drag.map(\.id), values.map(\.id)); XCTAssertEqual(try Data(contentsOf: imageURL), before)
        try store.retain(values.map(\.id))
        let model = LibraryModel(store: store); wait { model.ids.count == 3 }; _ = model.select(text.id); model.selectAll()
        model.draftText = "edited İstanbul 👋\n第二行"
        let selected = model.selectedIDs, ordered = model.actionIDs
        let updatedDrag = model.dragItems(text.id)
        XCTAssertEqual(model.selectedIDs, selected); XCTAssertEqual(updatedDrag.map(\.id), ordered)
        let updatedFile = try XCTUnwrap(updatedDrag.first { $0.id == text.id }?.sourceURL)
        XCTAssertEqual(try String(contentsOf: updatedFile, encoding: .utf8), model.draftText)
        XCTAssertEqual(try Data(contentsOf: imageURL), before)
    }
    func testYouTubeParserIgnoresHTMLAndRejectsMalformedOrUntrustedImages() throws {
        let data = Data(#"{"title":"Synthetic title","author_name":"Synthetic channel","thumbnail_url":"https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg","html":"<script>never execute</script>"}"#.utf8)
        let parsed = try LinkMetadataService.youtubeMetadata(data); XCTAssertEqual(parsed.0.title, "Synthetic title"); XCTAssertEqual(parsed.0.author, "Synthetic channel"); XCTAssertEqual(parsed.1?.host, "i.ytimg.com")
        let untrusted = try LinkMetadataService.youtubeMetadata(Data(#"{"thumbnail_url":"http://127.0.0.1/private"}"#.utf8)); XCTAssertNil(untrusted.1)
        var failed = false; do { _ = try LinkMetadataService.youtubeMetadata(Data("not json".utf8)) } catch { failed = true }; XCTAssertTrue(failed)
    }
    func testMetadataConcurrencyBackoffPrivateLinksAndUserTitle() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        var calls = 0
        let service = LinkMetadataService(store: store, enabled: { true }, fetch: { _ in calls += 1; try await Task.sleep(nanoseconds: 20_000_000); return LinkMetadata(title: "network", author: "channel") })
        var ids = [UUID]()
        for i in 0..<8 { ids.append(try store.captureLink(URL(string: "https://example.com/\(i)")!).id) }
        try store.update(ids[0]) { $0.title = "user title" }
        let secret = try store.captureLink(URL(string: "https://example.com/?token=private")!), local = try store.captureLink(URL(string: "http://192.168.1.1/")!)
        service.request(ids + [secret.id,local.id]); wait { service.pendingCount == 0 && calls == 8 }
        XCTAssertEqual(service.peakConcurrency, 2); XCTAssertEqual(try store.item(ids[0])?.title, "user title"); XCTAssertEqual(try store.item(secret.id)?.metadataState, "blocked")
        service.request(ids); RunLoop.current.run(until: Date().addingTimeInterval(0.05)); XCTAssertEqual(calls, 8)
        service.stop()
        var failedCalls = 0
        let failing = LinkMetadataService(store: store, enabled: { true }, fetch: { _ in failedCalls += 1; throw HistoryFiles.Failure.unsafeFile })
        let bad = try store.captureLink(URL(string: "https://example.com/offline")!); failing.request([bad.id]); wait { failing.pendingCount == 0 && failedCalls == 1 }; failing.request([bad.id]); XCTAssertEqual(failedCalls, 1); XCTAssertEqual(try store.item(bad.id)?.metadataState, "failed"); failing.stop()
    }
    func testMetadataCancellationDoesNotWriteLateResultOrRevealShelf() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let id = try store.captureLink(URL(string: "https://example.com/cancel")!).id; var enabled = true, calls = 0
        let service = LinkMetadataService(store: store, enabled: { enabled }, fetch: { _ in calls += 1; try? await Task.sleep(nanoseconds: 30_000_000); return LinkMetadata(title: "late result") })
        service.request([id]); wait { calls == 1 }; enabled = false; service.stop(); RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(try store.item(id)?.title, ""); XCTAssertEqual(try store.item(id)?.metadataState, "pending"); XCTAssertEqual(service.pendingCount, 0)
    }
    func testManualMetadataRefreshBypassesCacheAndKeepsUserTitle() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let id = try store.captureLink(URL(string: "https://example.com/refresh")!).id; var calls = 0
        let service = LinkMetadataService(store: store, enabled: { true }, fetch: { _ in calls += 1; return LinkMetadata(title: "Network \(calls)") })
        service.request([id]); wait { calls == 1 && service.pendingCount == 0 }
        XCTAssertEqual(try store.item(id)?.displayTitle, "Network 1"); XCTAssertEqual(try store.item(id)?.title, "")
        service.request([id], force: true); wait { calls == 2 && service.pendingCount == 0 }
        XCTAssertEqual(try store.item(id)?.displayTitle, "Network 2")
        try store.update(id) { $0.title = "My title" }
        service.request([id], force: true); wait { calls == 3 && service.pendingCount == 0 }
        XCTAssertEqual(try store.item(id)?.displayTitle, "My title"); XCTAssertEqual(try store.item(id)?.metadataTitle, "Network 3")
        service.stop()
    }
    func testNewNoteClearsNarrowFiltersAndOpensEditableDetails() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f), model = LibraryModel(store: store)
        model.setFavorites(true); model.setKind(.link); model.setDomain("example.com"); model.setDays(7)
        model.inspectorVisible = false; model.newNote(); wait { !model.loading && model.ids.count == 1 }
        XCTAssertEqual(model.query, LibraryQuery(scope: .saved, kind: .text)); XCTAssertTrue(model.inspectorVisible)
        XCTAssertEqual(model.inspected?.id, model.ids.first); model.draftText = "New draft"; XCTAssertTrue(model.flushEdits())
        XCTAssertEqual(try store.item(try XCTUnwrap(model.ids.first))?.text, "New draft")
    }
    func testCancelledOldJobCannotClearOrOverwriteNewRequestForSameLink() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let id = try store.captureLink(URL(string: "https://example.com/generation")!).id; var calls = 0
        let service = LinkMetadataService(store: store, enabled: { true }, fetch: { _ in calls += 1; let order = calls; try? await Task.sleep(nanoseconds: order == 1 ? 60_000_000 : 10_000_000); return LinkMetadata(title: order == 1 ? "old" : "fresh") })
        service.request([id]); wait { calls == 1 }; service.stop(); service.request([id]); wait { calls == 2 && service.pendingCount == 0 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08)); XCTAssertEqual(try store.item(id)?.displayTitle, "fresh"); service.stop()
    }
    func testTenThousandRecordsQueryAndPagingStayBoundedWithThousandImages() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        var records = [LibraryRecord]()
        for i in 0..<10000 {
            var record = LibraryRecord(id: UUID(), kind: i < 1000 ? .image : .text, createdAt: f.date.addingTimeInterval(Double(i)), updatedAt: f.date)
            record.retainedAt = f.date; record.onShelf = false; record.title = "Fixture \(i)"
            if record.kind == .image { record.path = try f.image().path } else { record.text = "İstanbul searchable note \(i) 中文" }
            records.append(record)
        }
        try store.importRecords(records)
        var durations = [Double]()
        for i in 0..<10 { let start = Date(); _ = try store.queryIDs(LibraryQuery(search: "searchable \(9000 + i)")); durations.append(Date().timeIntervalSince(start)) }
        print("Library model benchmark: 10000 records / 1000 images; search max \(Int((durations.max() ?? 0) * 1000)) ms")
        XCTAssertTrue((durations.max() ?? 0) < 1)
        let model = LibraryModel(store: store); wait { model.ids.count == 10000 }
        for i in stride(from: 0, to: 10000, by: 400) { model.requestVisible(Array(model.ids[i..<min(i + 20, model.ids.count)])); XCTAssertTrue(model.pendingPageCount <= 2) }
        let end = Array(model.ids.suffix(20)); model.requestVisible(end); wait { end.allSatisfy { model.summary($0) != nil } }
        XCTAssertTrue(model.cachedSummaryCount <= 12 * 80)
        let start = Date(); model.selectAll(); XCTAssertEqual(model.selectedIDs.count, 10000); _ = model.handleKey(key(124), editing: false)
        print("Library model benchmark: select all and arrow \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertTrue(Date().timeIntervalSince(start) < 1)
    }
    func testDatabaseSymlinksAndCorruptionNeverOverwriteOriginal() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let root = f.inbox.appendingPathComponent("Library"), target = f.folder.appendingPathComponent("protected.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); let bytes = Data("not a database".utf8); try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("library.sqlite"), withDestinationURL: target)
        var rejected = false; do { _ = try library(f) } catch { rejected = true }; XCTAssertTrue(rejected); XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.sqlite")); try bytes.write(to: root.appendingPathComponent("library.sqlite"))
        rejected = false; do { _ = try library(f) } catch { rejected = true }; XCTAssertTrue(rejected); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.sqlite")), bytes)
    }
    func testLibraryCopyUsesAllSelectedButPreviewCopyOnlyCurrentAndFailedCopyKeepsBoard() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; let store = try library(f)
        let image = try store.captureImage(try f.image()), text = try XCTUnwrap(store.captureText("second item")), link = try store.captureLink(URL(string: "https://example.com/third")!)
        try store.retain([image.id,text.id,link.id])
        let board = NSPasteboard(name: NSPasteboard.Name("library-copy-test-\(UUID())")); defer { board.releaseGlobally() }
        let model = LibraryModel(store: store, copyPasteboard: board); wait { model.ids.count == 3 }; model.selectAll(); model.copy()
        XCTAssertEqual(board.pasteboardItems?.count, 3); XCTAssertEqual(model.copiedIDs.count, 3)
        model.copyCurrent(text.id); XCTAssertEqual(board.string(forType: .string), "second item"); XCTAssertEqual(model.copiedIDs, [text.id]); XCTAssertEqual(model.selectedIDs.count, 3)
        let file = try XCTUnwrap(store.item(image.id)?.fileURL); try FileManager.default.removeItem(at: file)
        model.copy(); XCTAssertEqual(board.string(forType: .string), "second item")
        XCTAssertEqual(try store.item(text.id)?.text, "second item")
    }
    func testThreeLargeShelvesFitAvailableHeightWithoutChangingSavedSize() throws {
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium; Layout.maximumRowHeight = .greatestFiniteMagnitude }
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: try library(f))
        line.setSize(.large); line.setPresentation(.all, requestFocus: false); line.fitShelves(in: 650)
        XCTAssertTrue(line.panelHeight <= 650); XCTAssertEqual(line.size, .large); XCTAssertEqual(f.defaults.string(forKey: "lineSize"), "large")
        line.setPresentation(.images, requestFocus: false); line.fitShelves(in: 650); XCTAssertEqual(Layout.scale, Layout.Size.large.scale)
        for mode in ShelfPresentation.allCases { line.setPresentation(mode, requestFocus: false); line.fitShelves(in: 650); XCTAssertTrue(line.panelHeight <= 650) }
    }
    func testNativeLibraryOffscreenLayoutsInLightAndDarkAppearance() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try library(f), line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store)
        let folder = try store.createCollection("References")
        for i in 0..<12 {
            let record = try store.captureImage(try f.image()); try store.update(record.id) { $0.title = "Synthetic image \(i)" }; try store.assign([record.id], to: folder)
        }
        for i in 0..<8 { if let record = try store.captureText("Synthetic idea \(i)\nA readable second line\nİstanbul 中文") { try store.retain([record.id]); if i >= 6 { for tag in ["script", "İstanbul 中文", "ideas"] { try store.addTag(tag, to: [record.id]) } } } }
        let link = try store.captureLink(URL(string: "https://example.com/reference")!); try store.update(link.id) { $0.title = "A saved web reference with a long title İstanbul 中文" }; try store.toggleFavorite([link.id])
        for tag in ["research", "İstanbul 中文", "ideas"] { try store.addTag(tag, to: [link.id]) }
        let controller = LibraryWindowController(store: store, line: line, copyPasteboard: NSPasteboard(name: NSPasteboard.Name("offscreen-library-test-\(UUID())")))
        defer { controller.window?.contentView = nil; controller.close(); controller.model.copyPasteboard.releaseGlobally() }
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        guard let host = controller.window?.contentView else { throw HistoryFiles.Failure.unsafeFile }
        controller.window?.setContentSize(NSSize(width: 1280, height: 820)); wait { controller.model.ids.count == 21 && controller.model.cardSummary(link.id)?.tagCount == 3 }
        #if STANDALONE_TESTS
        let artifactFolder = "local/validation/library-native-clt"
        #else
        let artifactFolder = "local/validation/library-native-xcode"
        #endif
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(artifactFolder)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        func capture(_ suffix: String) throws {
            host.needsLayout = true; host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            let frame = host.superview ?? host
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: bitmap) }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: artifacts.appendingPathComponent("offscreen-library-\(suffix).png"))
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            controller.window?.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            try capture(suffix)
        }
        _ = controller.model.select(link.id); try capture("details")
        controller.model.listMode = true; try capture("list")
        controller.window?.setContentSize(NSSize(width: 870, height: 560)); try capture("small")
        controller.model.listMode = false
        // Search now belongs to the native window toolbar, outside contentView.
        let field = try XCTUnwrap(controller.toolbarController?.searchField)
        func collectionView(_ view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.lazy.compactMap { collectionView($0) }.first
        }
        wait {
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            return collectionView(host)?.numberOfItems(inSection: 0) == 21
        }
        let collection = try XCTUnwrap(collectionView(host))
        let unfilteredHeight = collection.frame.height
        controller.model.search = "Synthetic idea"
        wait { controller.model.ids.count == 8 && field.stringValue == "Synthetic idea" }
        wait { if let current = collectionView(host) { return current.numberOfItems(inSection: 0) == 8 && current.frame.height < unfilteredHeight }; return false }
        try capture("filtered")
        let filteredHeight = try XCTUnwrap(collectionView(host)).frame.height
        controller.model.clearFilters()
        wait { controller.model.ids.count == 21 && field.stringValue.isEmpty }
        wait { if let current = collectionView(host) { return current.numberOfItems(inSection: 0) == 21 && current.frame.height > filteredHeight }; return false }
    }
}
