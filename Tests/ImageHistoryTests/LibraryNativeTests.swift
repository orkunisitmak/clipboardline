import AppKit
import Combine
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class LibraryNativeTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate())
    }
    func testOpenLinkPreviewReceivesMetadataAndPinWithoutRepublishingIDs() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let record = try store.captureLink(URL(string: "https://example.com/pending")!); try store.retain([record.id])
        let model = LibraryModel(store: store)
        wait { model.ids == [record.id] && !model.loading }
        var publications = 0
        let subscription = model.$ids.dropFirst().sink { _ in publications += 1 }; defer { subscription.cancel() }
        let controller = LibraryPreviewController(model: model); defer { controller.close() }
        controller.show(record.id)
        let preview = try XCTUnwrap(controller.link); XCTAssertFalse(preview.hasThumbnail)
        let thumbnail = try f.image()
        try store.update(record.id) { $0.metadataTitle = "Updated video title"; $0.author = "Synthetic author"; $0.thumbnailPath = thumbnail.path; $0.metadataState = "ready" }
        func labels(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels) }
        wait { preview.hasThumbnail && (preview.window.contentView.map { labels($0).contains("Updated video title") } ?? false) && !model.loading }
        try store.toggleFavorite([record.id])
        wait { preview.controls.pinButton.accessibilityLabel() == L("Unpin") && !model.loading }
        XCTAssertEqual(publications, 0); XCTAssertEqual(controller.currentID, record.id)
    }
    func testAddToFolderMenuTellsSameNamedSubfoldersApart() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let work = try store.createCollection("Work"), personal = try store.createCollection("Personal")
        _ = try store.createCollection("2024", parent: work); _ = try store.createCollection("2024", parent: personal)
        let note = try XCTUnwrap(store.captureText("Quarterly plan")); try store.retain([note.id])
        let model = LibraryModel(store: store), controller = LibraryTableController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller; defer { window.contentViewController = nil }
        wait { model.ids.count == 1 && !model.loading && controller.table.numberOfRows == 1 }
        controller.table.layoutSubtreeIfNeeded()
        let rect = controller.table.rect(ofRow: 0), point = controller.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let submenu = try XCTUnwrap(try XCTUnwrap(controller.table.menu(for: event)).items.first { $0.title == L("Add to folder") }?.submenu)
        let titles = submenu.items.map(\.title)
        XCTAssertTrue(titles.contains("Work / 2024")); XCTAssertTrue(titles.contains("Personal / 2024")); XCTAssertFalse(titles.contains("2024"))
    }
    func testClosedLibraryDefersCaptureQueriesAndRefreshesOnceOnReopen() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let first = try XCTUnwrap(store.captureText("first temporary note"))
        let controller = LibraryWindowController(store: store, line: Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store))
        let model = controller.model, window = try XCTUnwrap(controller.window)
        defer { window.contentViewController = nil }
        model.changeScope(.recent); wait { model.ids == [first.id] && model.cardSummary(first.id) != nil && !model.loading }
        XCTAssertTrue(model.select(first.id)); model.draftNote = "Saved before closing"
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(model.updatesSuspended); XCTAssertEqual(try store.item(first.id)?.note, "Saved before closing")
        let closedCount = model.reloadCount
        for i in 0..<20 { _ = try store.captureText("captured while Library closed \(i)") }
        try store.update(first.id) { $0.title = "Updated while closed" }
        model.requestVisible([first.id])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.reloadCount, closedCount); XCTAssertEqual(model.cachedSummaryCount, 0)
        XCTAssertEqual(model.pendingPageCount, 0); XCTAssertEqual(model.ids, [first.id])
        model.resumeUpdates()
        wait { model.ids.count == 21 && model.cardSummary(first.id)?.record.title == "Updated while closed" && !model.loading }
        XCTAssertFalse(model.updatesSuspended); XCTAssertEqual(model.reloadCount, closedCount + 1)
        XCTAssertEqual(model.focusedID, first.id); XCTAssertEqual(model.selectedIDs, [first.id])
        XCTAssertEqual(model.draftNote, "Saved before closing")
    }
    func testClosingDuringSearchDebounceRestoresQueryAndFailedDraftBlocksSuspension() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let first = try XCTUnwrap(store.captureText("needle note")); _ = try store.captureText("other note")
        let model = LibraryModel(store: store); model.changeScope(.recent)
        wait { model.ids.count == 2 && !model.loading }
        model.search = "needle"; XCTAssertTrue(model.suspendUpdates())
        let closedCount = model.reloadCount
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(model.reloadCount, closedCount); XCTAssertEqual(model.query.search, "")
        model.resumeUpdates(); wait { model.ids == [first.id] && !model.loading }
        XCTAssertEqual(model.query.search, "needle"); XCTAssertEqual(model.query.sort, .relevance)
        let beforeClear = model.reloadCount; model.clearFilters()
        wait { model.ids.count == 2 && !model.loading }
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(model.reloadCount, beforeClear + 1); XCTAssertEqual(model.query.sort, .newest)
        XCTAssertTrue(model.select(first.id))
        let failed = String(repeating: "x", count: TextClipboardWatcher.maximumDataBytes + 1)
        model.draftText = failed; XCTAssertFalse(model.suspendUpdates())
        XCTAssertFalse(model.updatesSuspended); XCTAssertEqual(model.draftText, failed); XCTAssertEqual(model.focusedID, first.id)
        model.draftText = "fixed"; XCTAssertTrue(model.flushEdits())
    }
    func testNativeToolbarAndSplitColumnsPreserveRecordsAndInspectorPreference() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let record = try XCTUnwrap(store.captureText("native window fixture")); try store.retain([record.id])
        let before = try store.item(record.id)
        let controller = LibraryWindowController(store: store, line: Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store))
        let window = try XCTUnwrap(controller.window)
        defer { window.contentViewController = nil }
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.toolbar?.allowsUserCustomization == true)
        XCTAssertEqual(controller.splitController.splitViewItems.count, 3)
        let searchItem = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == LibraryToolbarController.searchID } as? NSSearchToolbarItem)
        XCTAssertTrue(searchItem.searchField === controller.toolbarController.searchField)
        let liveField = searchItem.searchField, liveSuperview = liveField.superview, liveWindow = liveField.window
        let liveToolbar = try XCTUnwrap(window.toolbar)
        let paletteItem = try XCTUnwrap(controller.toolbarController.toolbar(liveToolbar, itemForItemIdentifier: LibraryToolbarController.searchID, willBeInsertedIntoToolbar: false) as? NSSearchToolbarItem)
        // AppKit owns each NSSearchToolbarItem's field container and layout.
        // Creating a palette prototype must preserve the live item; moving the
        // prototype field out of its managed container is not a valid probe.
        XCTAssertFalse(paletteItem.searchField === liveField)
        XCTAssertFalse(paletteItem.searchField is LibrarySearchTextField)
        XCTAssertNil(paletteItem.toolbar)
        XCTAssertTrue(searchItem.toolbar === liveToolbar)
        XCTAssertTrue(liveToolbar.items.first { $0.itemIdentifier == LibraryToolbarController.searchID } === searchItem)
        XCTAssertTrue(searchItem.searchField === liveField)
        XCTAssertTrue(liveField.superview === liveSuperview); XCTAssertTrue(liveField.window === liveWindow)
        XCTAssertTrue(liveField === controller.toolbarController.searchField)
        XCTAssertEqual(controller.splitController.splitViewItems[0].behavior, .sidebar)
        XCTAssertEqual(controller.splitController.inspectorItem.behavior, .inspector)
        controller.model.inspectorVisible = false
        XCTAssertTrue(controller.splitController.inspectorItem.isCollapsed)
        XCTAssertFalse(f.defaults.bool(forKey: "libraryInspectorVisible"))
        controller.splitController.inspectorItem.isCollapsed = false
        XCTAssertTrue(controller.model.inspectorVisible)
        window.setContentSize(NSSize(width: 870, height: 560)); window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.splitController.splitViewItems[1].viewController.view.frame.width >= 359)
        XCTAssertEqual(try store.item(record.id), before)
        try controller.model.keyboardBindings.set([KeyShortcut(keyCode: 38, modifiers: 0, keyLabel: "J")], for: .search)
        let typing = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        XCTAssertFalse(controller.model.handleKey(typing, editing: true))
    }
    func testSidebarArrowKeysAndNestedScopeUseNativeSelectionAndRevealAncestors() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let parent = try store.createCollection("Parent"), child = try store.createCollection("Child", parent: parent)
        let controller = LibraryWindowController(store: store, line: Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store))
        let window = try XCTUnwrap(controller.window); defer { window.contentViewController = nil }
        func outlineIn(_ view: NSView) -> NSOutlineView? { if let outline = view as? NSOutlineView { return outline }; return view.subviews.lazy.compactMap { outlineIn($0) }.first }
        let outline = try XCTUnwrap(outlineIn(controller.splitController.sidebar.view))
        window.makeFirstResponder(outline)
        XCTAssertTrue(window.firstResponder === outline)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        XCTAssertEqual(controller.model.query.scope, .favorites)
        let folders = try XCTUnwrap((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? LibrarySidebarNode }.first { $0.key == "folders" })
        outline.collapseItem(folders, collapseChildren: true)
        controller.model.changeScope(.collection(child))
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? LibrarySidebarNode)
        XCTAssertEqual(selected.scope, .collection(child)); XCTAssertTrue(outline.isItemExpanded(folders))
    }
    func testNativeListSortSelectionAndCombinedDragPayloadKeepRecordIdentities() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        var records = [LibraryRecord]()
        for i in 0..<30 {
            var record = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date.addingTimeInterval(Double(i)), updatedAt: f.date)
            record.title = String(format: "Item %02d", i); record.text = "Fixture \(i) · İstanbul"; record.retainedAt = f.date; records.append(record)
        }
        try store.importRecords(records)
        let model = LibraryModel(store: store), controller = LibraryTableController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller; defer { window.contentViewController = nil }
        wait { model.ids.count == 30 && controller.table.numberOfRows == 30 && model.cardSummary(model.ids[0]) != nil }
        XCTAssertEqual(controller.table.numberOfColumns, 4)
        controller.table.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        wait { model.query.sort == .title && model.ids.first == records.first?.id && !model.loading }
        controller.table.selectRowIndexes(IndexSet([2,4]), byExtendingSelection: false)
        XCTAssertEqual(model.selectedIDs, Set([records[2].id, records[4].id]))
        let writer = try XCTUnwrap(controller.tableView(controller.table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: .string), "Fixture 2 · İstanbul\n\nFixture 4 · İstanbul")
        XCTAssertEqual(writer.string(forType: NSPasteboard.PasteboardType("local.clipboardline.library-id")), records[2].id.uuidString)
        let next = try XCTUnwrap(controller.tableView(controller.table, pasteboardWriterForRow: 4) as? NSPasteboardItem)
        XCTAssertEqual(next.string(forType: NSPasteboard.PasteboardType("local.clipboardline.library-id")), records[4].id.uuidString)
        XCTAssertEqual(model.actionIDs, [records[2].id, records[4].id])
        controller.table.sortDescriptors = [NSSortDescriptor(key: "title", ascending: false)]
        wait { model.query.sort == .titleDescending && model.ids.first == records.last?.id && !model.loading }
        XCTAssertEqual(model.selectedIDs, Set([records[2].id, records[4].id]))
        _ = model.select(records[2].id)
        let fresh = try XCTUnwrap(controller.tableView(controller.table, pasteboardWriterForRow: try XCTUnwrap(model.index(of: records[2].id))) as? NSPasteboardItem)
        XCTAssertEqual(fresh.string(forType: .string), "Fixture 2 · İstanbul")
    }
    func testInspectorRelationshipsRefreshAfterRenameAndRemovalAndRemainDuringDrafts() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let item = try XCTUnwrap(store.captureText("native inspector")), folder = try store.createCollection("References")
        try store.assign([item.id], to: folder); try store.addTag("research", to: [item.id])
        let model = LibraryModel(store: store); wait { model.ids.contains(item.id) }
        XCTAssertTrue(model.select(item.id)); XCTAssertEqual(model.inspectedCollections.map(\.id), [folder])
        let tag = try XCTUnwrap(model.inspectedTags.first)
        model.draftNote = "A local draft"; XCTAssertEqual(model.inspectedTags.first?.name, "research")
        XCTAssertTrue(model.flushEdits()); try store.renameCollection(folder, name: "Renamed")
        wait { model.inspectedCollections.first?.name == "Renamed" && !model.loading }
        try store.renameTag(tag.id, name: "updated")
        wait { model.inspectedTags.first?.name == "updated" && !model.loading }
        model.removeTag(tag.id); wait { model.inspectedTags.isEmpty && !model.loading }
        model.unassign(folder); wait { model.inspectedCollections.isEmpty && !model.loading }
        XCTAssertEqual(try store.item(item.id)?.note, "A local draft")
    }
    func testTenThousandRecordsDoNotRebuildUnchangedVisibleCards() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox)
        let records = (0..<10000).map { i -> LibraryRecord in
            var record = LibraryRecord(id: UUID(), kind: .text, createdAt: f.date.addingTimeInterval(Double(i)), updatedAt: f.date)
            record.title = "Synthetic note \(i)"; record.text = "İstanbul · searchable note \(i)"; record.retainedAt = f.date; record.onShelf = false
            return record
        }
        try store.importRecords(records)
        let model = LibraryModel(store: store), line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store)
        let controller = LibraryCollectionController(model: model, line: line)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        wait { model.ids.count == 10000 && model.cardSummary(model.ids[0]) != nil }
        controller.view.layoutSubtreeIfNeeded(); controller.refresh()
        let cards = model.ids.prefix(12).map { id -> (UUID, LibraryCollectionItem) in
            let item = LibraryCollectionItem(); controller.configure(item, id: id); return (id, item)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        let before = controller.cardConfigurationCount, start = Date()
        for _ in 0..<100 { for (id, item) in cards { controller.configure(item, id: id) } }
        var result: [String: Any] = ["records": model.ids.count, "cards": 12, "passes": 100, "cardConfigurations": controller.cardConfigurationCount - before, "milliseconds": Date().timeIntervalSince(start) * 1000, "cachedSummaries": model.cachedSummaryCount]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if STANDALONE_TESTS
        let runner = "clt"
        #else
        let runner = "xcode"
        #endif
        result["runner"] = runner
        let output = root.appendingPathComponent("local/validation/library-native-benchmark-\(runner).json")
        XCTAssertTrue(model.cachedSummaryCount <= 960)
        XCTAssertEqual(controller.cardConfigurationCount - before, 0)
        _ = model.select(cards[0].0)
        controller.configure(cards[0].1, id: cards[0].0)
        XCTAssertTrue(controller.cardConfigurationCount > before)
        // Reference the old full-result scan to measure the actual selection
        // workload removed from copy, drag and inspector actions. This is a
        // local code-path benchmark, never a claim about scroll FPS.
        var baselineCount = 0, optimizedCount = 0
        let scanStart = Date()
        for _ in 0..<300 { baselineCount += model.ids.filter { model.selectedIDs.contains($0) || (model.selectedIDs.isEmpty && model.focusedID == $0) }.count }
        result["referenceActionScanMilliseconds"] = Date().timeIntervalSince(scanStart) * 1000
        let actionStart = Date()
        for _ in 0..<300 { optimizedCount += model.actionIDs.count }
        result["actionIDsMilliseconds"] = Date().timeIntervalSince(actionStart) * 1000; result["actionIterations"] = 300
        XCTAssertEqual(baselineCount, optimizedCount); XCTAssertEqual(optimizedCount, 300)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: output)
    }
}
