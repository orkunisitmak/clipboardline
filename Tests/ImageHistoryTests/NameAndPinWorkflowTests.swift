import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class NameAndPinWorkflowTests: HistoryTestCase {
    private func key(_ code: UInt16 = 35, flags: NSEvent.ModifierFlags = .option, text: String = "p") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Name-and-pin workflow did not settle")
    }
    private func line(_ f: SyntheticFixture, store: LibraryStore) -> Line {
        let value = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
            copyImage: { _ in }, copyText: { _ in }, library: store)
        value.setPresentation(.all, requestFocus: false); return value
    }
    private func populate(_ f: SyntheticFixture, store: LibraryStore) throws {
        for i in 0..<2 {
            _ = try store.captureImage(f.image())
            _ = try store.captureText("synthetic unnamed note \(i)")
            _ = try store.captureLink(URL(string: "https://example.com/name-pin/\(i)")!)
            f.date += 1
        }
    }
    func testNameAndPinShortcutKeepsExistingPinDefaultsAndSupportsRemapping() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        for context in KeyboardContext.allCases where context != .imageMarkup {
            XCTAssertEqual(bindings.action(for: key(), in: context), .nameAndPin)
            XCTAssertEqual(bindings.action(for: key(flags: []), in: context), .pin)
            XCTAssertEqual(bindings.action(for: key(flags: .command), in: context), .pin)
            XCTAssertEqual(bindings.action(for: key(flags: .shift), in: context), .pinToFolder)
        }
        XCTAssertNil(bindings.action(for: key(), in: .imageMarkup))
        let custom = KeyShortcut(keyCode: 45, modifiers: cmdKey | optionKey, keyLabel: "N")
        try bindings.set([custom], for: .nameAndPin)
        let reloaded = KeyboardBindings(defaults: f.defaults)
        XCTAssertEqual(reloaded.shortcuts(.nameAndPin), [custom])
        XCTAssertNil(reloaded.action(for: key(), in: .line))
        XCTAssertEqual(reloaded.action(for: key(45, flags: [.command, .option], text: "n"), in: .library), .nameAndPin)
        XCTAssertThrowsError(try bindings.set([KeyShortcut(keyCode: 35, modifiers: 0, keyLabel: "P")], for: .nameAndPin))
        try bindings.set([], for: .nameAndPin)
        XCTAssertNil(reloaded.action(for: key(45, flags: [.command, .option], text: "n"), in: .library))
        try bindings.reset(.nameAndPin)
        XCTAssertEqual(reloaded.action(for: key(), in: .imagePreview), .nameAndPin)
    }
    func testShelfNamingSnapshotsVisibleBatchAndLeavesSearchTypingAlone() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let line = line(f, store: store)
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
        var requested = [[UUID]](), singles = [UUID]()
        line.onNameAndPinBatchRequested = { requested.append($0) }
        line.onNameAndPinRequested = { singles.append($0) }
        for shelf in Shelf.allCases {
            line.focusShelf(shelf, requestFocus: false)
            line.selectAllActive()
            let expected = line.activeActionIDs
            XCTAssertEqual(expected.count, 2)
            XCTAssertTrue(keyboard.handle(key()))
            XCTAssertEqual(requested.last, expected)
            for id in expected { XCTAssertFalse(try store.item(id)?.favorite == true, "Opening the naming prompt must not pin yet") }
            line.moveToShelfBoundary(last: true)
            XCTAssertEqual(requested.last, expected, "The queued snapshot must not follow subsequent selection changes")
            XCTAssertEqual(line.activeActionIDs, expected.suffix(1).map { $0 })
        }
        XCTAssertEqual(requested.count, 3); XCTAssertTrue(singles.isEmpty)
        line.beginShelfSearch(.texts)
        XCTAssertFalse(keyboard.handle(key()))
        XCTAssertEqual(requested.count, 3)
    }
    func testMenuNameAndPinNamesTheWholeSelectionLikeTheKey() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let line = line(f, store: store)
        var batches = [[UUID]](), singles = [UUID]()
        line.onNameAndPinBatchRequested = { batches.append($0) }
        line.onNameAndPinRequested = { singles.append($0) }
        for shelf in Shelf.allCases {
            line.focusShelf(shelf, requestFocus: false)
            line.selectAllActive()
            let expected = line.activeActionIDs
            XCTAssertEqual(expected.count, 2)
            line.requestNameAndPin(expected[1], on: shelf)
            XCTAssertEqual(batches.last, expected); XCTAssertTrue(singles.isEmpty)
        }
        line.focusShelf(.texts, requestFocus: false)
        let outside = try XCTUnwrap(line.texts.displayEntries.last?.id)
        line.texts.select(outside, width: line.viewportWidth)
        line.requestNameAndPin(outside, on: .texts)
        XCTAssertEqual(singles, [outside]); XCTAssertEqual(batches.count, 3)

        let first = try XCTUnwrap(store.captureText("first menu note")), second = try XCTUnwrap(store.captureText("second menu note"))
        try store.retain([first.id, second.id])
        let model = LibraryModel(store: store)
        wait { model.ids.contains(first.id) && model.ids.contains(second.id) }
        model.selectAll()
        var requested = [[UUID]](), single = [UUID]()
        model.onNameAndPinBatchRequested = { requested.append($0) }; model.onNameAndPinRequested = { single.append($0) }
        model.requestNameAndPin(first.id)
        XCTAssertEqual(requested, [model.actionIDs]); XCTAssertGreaterThan(requested[0].count, 1); XCTAssertTrue(single.isEmpty)
        XCTAssertTrue(model.select(first.id)); model.requestNameAndPin(first.id)
        XCTAssertEqual(single, [first.id]); XCTAssertEqual(requested.count, 1)
    }
    func testLibraryNamingFlushesDraftAndSnapshotsSelectionWithoutInterceptingNativeEditors() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let first = try XCTUnwrap(store.captureText("first synthetic note")), second = try XCTUnwrap(store.captureText("second synthetic note"))
        try store.retain([first.id, second.id])
        let model = LibraryModel(store: store)
        wait { model.ids.count == 2 }
        XCTAssertTrue(model.select(first.id)); model.selectAll()
        let focused = try XCTUnwrap(model.focusedID), expected = model.ids
        var requested = [[UUID]](), savedBeforePrompt = false
        model.onNameAndPinBatchRequested = { ids in
            requested.append(ids); savedBeforePrompt = (try? store.item(focused)?.note) == "saved before name prompt"
        }
        model.draftNote = "saved before name prompt"
        XCTAssertFalse(model.handleKey(key(), editing: true)); XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(model.handleKey(key(), editing: false))
        XCTAssertEqual(requested, [expected]); XCTAssertTrue(savedBeforePrompt)
        XCTAssertEqual(model.selectedIDs, [first.id, second.id])
        XCTAssertTrue(model.select(second.id))
        XCTAssertEqual(requested, [expected])
    }
    func testLibraryNameBatchUsesFilteredSortedVisibleOrderAcrossKinds() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let records = try store.records(try store.queryIDs(LibraryQuery(scope: .recent)))
        try store.retain(records.map(\.id))
        let model = LibraryModel(store: store)
        wait { model.ids.count == 6 }
        let ordered = model.ids
        let chosen = try LibraryKind.allCases.map { kind in try XCTUnwrap(records.first { $0.kind == kind }?.id) }.reversed()
        for (index, id) in chosen.enumerated() { XCTAssertTrue(model.select(id, toggle: index > 0)) }
        let expected = ordered.filter { chosen.contains($0) }
        var requested = [[UUID]](); model.onNameAndPinBatchRequested = { requested.append($0) }
        XCTAssertTrue(model.handleKey(key(), editing: false))
        XCTAssertEqual(requested, [expected])
        XCTAssertEqual(Set(try store.records(requested[0]).map(\.kind)), Set(LibraryKind.allCases))
        model.setKind(.text)
        wait { model.ids.count == 2 }
        model.selectAll()
        XCTAssertTrue(model.handleKey(key(), editing: false))
        XCTAssertEqual(requested.last, model.ids)
        XCTAssertEqual(try store.records(try XCTUnwrap(requested.last)).map(\.kind), [.text, .text])
    }
    func testShelfBatchNamingAdvancesFocusInSamePanelAndEscapeKeepsRemainingUnchanged() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let line = line(f, store: store), app = AppDelegate(line: line, watchesFiles: false)
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
        // Avoid starting application-wide clipboard watchers or global hotkeys.
        line.onNameAndPinBatchRequested = { [weak app] in app?.showNameAndPin($0) }
        defer { app.nameAndPinPicker?.window.close(); line.onNameAndPinBatchRequested = nil }
        for shelf in Shelf.allCases {
            line.focusShelf(shelf, requestFocus: false); line.selectAllActive()
            let expected = line.activeActionIDs, before = try store.records(expected)
            XCTAssertTrue(keyboard.handle(key()))
            let picker = try XCTUnwrap(app.nameAndPinPicker)
            XCTAssertEqual(picker.orderedIDs, expected); XCTAssertEqual(picker.id, expected[0])
            XCTAssertEqual(line.focusedActionID, expected[0]); XCTAssertEqual(line.activeActionIDs, expected)
            picker.nameField.stringValue = "Batch \(shelf.rawValue) first"
            XCTAssertTrue(picker.handle(key(36, flags: [], text: "")))
            XCTAssertTrue(app.nameAndPinPicker === picker, "Enter must keep the same panel open for the next item")
            XCTAssertEqual(picker.id, expected[1]); XCTAssertEqual(line.focusedActionID, expected[1])
            XCTAssertEqual(line.activeActionIDs, expected, "Advancing focus must preserve the batch selection")
            XCTAssertEqual(try store.item(expected[0])?.title, "Batch \(shelf.rawValue) first")
            XCTAssertTrue(try store.item(expected[0])?.favorite == true)
            picker.nameField.stringValue = "Uncommitted next name"
            XCTAssertTrue(picker.handle(key(53, flags: [], text: "")))
            XCTAssertNil(app.nameAndPinPicker)
            XCTAssertEqual(try store.item(expected[1]), before[1], "Escape must leave unvisited and unfinished targets unchanged")
        }
    }
    func testLibraryBatchNamingKeepsCapturedQueueWhenPinningChangesScope() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let line = line(f, store: store), controller = LibraryWindowController(store: store, line: line)
        defer { controller.nameAndPinPicker?.window.close(); controller.close() }
        let model = controller.model
        model.changeScope(.recent)
        wait { model.ids.count == 6 }; model.selectAll()
        let snapshot = model.actionIDs, unchanged = try store.records(Array(snapshot.dropFirst(2)))
        XCTAssertTrue(model.handleKey(key(), editing: false))
        let picker = try XCTUnwrap(controller.nameAndPinPicker)
        XCTAssertEqual(picker.orderedIDs, snapshot); XCTAssertEqual(model.focusedID, snapshot[0])
        picker.nameField.stringValue = "Saved first"
        XCTAssertTrue(picker.handle(key(36, flags: [], text: "")))
        wait { model.ids.count == 5 }
        XCTAssertFalse(model.ids.contains(snapshot[0]))
        XCTAssertEqual(picker.id, snapshot[1]); XCTAssertEqual(model.focusedID, snapshot[1])
        XCTAssertEqual(picker.orderedIDs, snapshot, "Filtered removals must not reorder or expand the original batch")
        picker.nameField.stringValue = "Saved second"
        XCTAssertTrue(picker.handle(key(36, flags: [], text: "")))
        wait { model.ids.count == 4 }
        XCTAssertEqual(picker.id, snapshot[2]); XCTAssertTrue(controller.nameAndPinPicker === picker)
        XCTAssertTrue(picker.handle(key(53, flags: [], text: "")))
        XCTAssertNil(controller.nameAndPinPicker)
        XCTAssertEqual(try store.records(Array(snapshot.dropFirst(2))), unchanged)
        XCTAssertTrue(try store.item(snapshot[0])?.favorite == true)
        XCTAssertTrue(try store.item(snapshot[1])?.favorite == true)
    }
    func testShelfPreviewsOpenNamingForDisplayedItemAndPreservePreviewOnCancel() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let line = line(f, store: store), app = AppDelegate(line: line, watchesFiles: false)
        for shelf in Shelf.allCases {
            let id: UUID
            switch shelf {
            case .images: id = try XCTUnwrap(line.displayItems.first?.id); app.showPreview(id)
            case .texts: id = try XCTUnwrap(line.texts.displayEntries.first?.id); app.showTextPreview(id)
            case .links: id = try XCTUnwrap(line.links.displayEntries.first?.id); app.showLinkPreview(id)
            }
            let panel = try XCTUnwrap(app.previewWindow)
            XCTAssertTrue(panel.onKey?(key()) ?? false)
            let picker = try XCTUnwrap(app.nameAndPinPicker)
            XCTAssertEqual(picker.id, id); XCTAssertTrue(picker.window.parent === panel)
            XCTAssertTrue(picker.handle(key(53, flags: [], text: "")))
            XCTAssertNil(app.nameAndPinPicker)
            XCTAssertTrue(app.previewWindow === panel); XCTAssertEqual(app.previewSession?.currentID, id)
            XCTAssertTrue(panel.isVisible); XCTAssertFalse(try store.item(id)?.favorite == true)
            panel.close()
        }
    }
    func testTextPreviewOptionPinKeepsEditingKeysAndFlushesBeforeBrowsingNaming() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let note = try XCTUnwrap(store.captureText("synthetic draft"))
        let line = line(f, store: store), app = AppDelegate(line: line, watchesFiles: false)
        app.showTextPreview(note.id)
        let preview = try XCTUnwrap(app.textPreview)
        defer { app.nameAndPinPicker?.window.close(); preview.window.close() }
        preview.beginEditing(); preview.textView.string = "synthetic edited content"
        preview.textDidChange(Notification(name: NSText.didChangeNotification, object: preview.textView))
        XCTAssertFalse(preview.routeKey(key())); XCTAssertNil(app.nameAndPinPicker)
        XCTAssertTrue(preview.finishEditing()); XCTAssertTrue(preview.routeKey(key()))
        XCTAssertEqual(app.nameAndPinPicker?.id, note.id)
        XCTAssertEqual(try store.item(note.id)?.text, "synthetic edited content")
    }
    func testLibraryPreviewNamingTargetsDisplayedItemAcrossAllKinds() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        try populate(f, store: store)
        let records = try store.records(try store.queryIDs(LibraryQuery(scope: .recent)))
        try store.retain(records.map(\.id))
        let line = line(f, store: store), controller = LibraryWindowController(store: store, line: line)
        defer { controller.nameAndPinPicker?.window.close(); controller.dismissPreviews(); controller.close() }
        wait { controller.model.ids.count == 6 }
        for record in records {
            controller.model.onPreview?(record.id)
            let panel = try XCTUnwrap(controller.previewWindow as? ActionPreviewPanel)
            XCTAssertTrue(panel.onKey?(key()) ?? false)
            let picker = try XCTUnwrap(controller.nameAndPinPicker)
            XCTAssertEqual(picker.id, record.id); XCTAssertTrue(picker.window.parent === panel)
            XCTAssertTrue(picker.handle(key(53, flags: [], text: "")))
            XCTAssertNil(controller.nameAndPinPicker); XCTAssertTrue(controller.previewWindow === panel)
        }
    }
}
