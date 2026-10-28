import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

final class FavoritesTests: HistoryTestCase {
    @MainActor private func fixture(_ body: (SyntheticFixture) throws -> Void) throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; try body(f)
    }
    @MainActor func testPinnedClipboardSurvivesExpiryAndRestart() throws {
        try fixture { f in
            let line = f.line(), url = try f.image()
            let id = try XCTUnwrap(line.hang(url, quietly: true)); XCTAssertTrue(try line.togglePin(id))
            f.date.addTimeInterval(60 * 86400); line.setRetentionDays(1)
            XCTAssertEqual(line.items.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let restart = f.line(); XCTAssertTrue(restart.items[0].pinned)
            XCTAssertFalse(try restart.togglePin(restart.items[0].id)); restart.prune()
            XCTAssertTrue(restart.items.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.folder.appendingPathComponent(".test-trash").path).count, 1)
        }
    }
    @MainActor func testExternalPinCreatesPrivateCopyAndPreservesOriginal() throws {
        try fixture { f in
            let original = try f.image(owned: false), bytes = try Data(contentsOf: original), line = f.line()
            let id = try XCTUnwrap(line.hang(original, quietly: true)); try line.togglePin(id)
            let copy = line.items[0].url
            XCTAssertFalse(copy == original); XCTAssertTrue(line.isAppCopy(id))
            XCTAssertEqual(line.items[0].originalPath, original.path); XCTAssertEqual(try Data(contentsOf: copy), bytes)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            f.date.addTimeInterval(90 * 86400); line.prune(); XCTAssertEqual(line.items.count, 1)
            line.select(id); line.trashSelection(line.trashSelectionSnapshot(), confirmed: true)
            XCTAssertTrue(line.items.isEmpty); XCTAssertEqual(try Data(contentsOf: original), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        }
    }
    @MainActor func testFavoritesFilterAndClearPreservePins() throws {
        try fixture { f in
            let line = f.line()
            let pinned = try XCTUnwrap(line.hang(try f.image(), quietly: true)); try line.togglePin(pinned)
            _ = line.hang(try f.image(), quietly: true)
            line.setFavoritesOnly(true); XCTAssertEqual(line.displayItems.map(\.id), [pinned])
            line.selectAll(); XCTAssertEqual(line.selectedItems.count, 1)
            line.setFavoritesOnly(false); XCTAssertTrue(line.selectedItems.isEmpty)
            line.clear(); XCTAssertEqual(line.items.map(\.id), [pinned]); XCTAssertTrue(f.line().items[0].pinned)
        }
    }
    @MainActor func testOldMetadataAndCorruptFavoritesRecovery() throws {
        try fixture { f in
            let url = try f.image()
            let old: [[String: Any]] = [["path": url.path, "capturedAt": f.date.timeIntervalSinceReferenceDate]]
            f.defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "imageHistoryV1")
            let history = f.history(); XCTAssertFalse(history.entries[0].pinned)
            let copy = try history.files.makeFavoriteCopy(of: try f.image(owned: false))
            f.defaults.set(Data("invalid".utf8), forKey: "imageHistoryV1")
            f.date.addTimeInterval(90 * 86400)
            let recovered = f.history()
            XCTAssertTrue(recovered.entries.contains(where: { $0.url.path == copy.path && $0.pinned }))
        }
    }
    @MainActor func testSymlinkFavoriteIsRejectedAndOriginalKept() throws {
        try fixture { f in
            let url = try f.image(owned: false), link = f.folder.appendingPathComponent("link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let files = HistoryFiles(inbox: f.inbox, moveToTrash: fixtureTrash(f.folder))
            var rejected = false
            do { _ = try files.makeFavoriteCopy(of: link) } catch { rejected = true }
            XCTAssertTrue(rejected); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    @MainActor func testFailedExpiryAndTrashKeepRecordForRetry() throws {
        try fixture { f in
            let url = try f.image(); var fail = true
            let history = ImageHistory(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: { source in
                if fail { throw HistoryFiles.Failure.unsafeFile }; return try fixtureTrash(f.folder)(source)
            })
            history.add(url); f.date.addTimeInterval(31 * 86400); history.prune()
            XCTAssertEqual(history.entries.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            fail = false; history.prune(); XCTAssertTrue(history.entries.isEmpty)
        }
    }
    @MainActor func testMultiSelectionRangeToggleCancelAndFilter() throws {
        try fixture { f in
            let line = f.line(); for _ in 0..<6 { line.hang(try f.image(), quietly: true) }
            let ids = line.items.map(\.id)
            line.select(ids[1]); line.select(ids[4], extending: true); XCTAssertEqual(line.selectedIDs, Set(ids[1...4]))
            line.select(ids[2], toggle: true); XCTAssertEqual(line.selectedItems.count, 3)
            line.cancelSelection(); XCTAssertTrue(line.selectedItems.isEmpty); XCTAssertNil(line.focusedID)
            line.selectAll(); XCTAssertEqual(line.selectedItems.count, 6)
            line.setFavoritesOnly(true); XCTAssertTrue(line.selectedItems.isEmpty)
        }
    }
    @MainActor func testTrashConfirmationSnapshotKeepsOriginalAndIgnoresNewSelection() throws {
        try fixture { f in
            let line = f.line(), original = try f.image(owned: false), owned = try f.image(), other = try f.image()
            let originalID = try XCTUnwrap(line.hang(original, quietly: true)), ownedID = try XCTUnwrap(line.hang(owned, quietly: true))
            let otherID = try XCTUnwrap(line.hang(other, quietly: true))
            line.select(originalID); line.select(ownedID, toggle: true)
            let snapshot = line.trashSelectionSnapshot(); XCTAssertEqual(snapshot.appCopies, 1); XCTAssertEqual(snapshot.originals, 1)
            XCTAssertEqual(line.trashSelection(snapshot, confirmed: false), 0); XCTAssertEqual(line.items.count, 3)
            line.select(otherID)
            XCTAssertEqual(line.trashSelection(snapshot, confirmed: true), 2)
            XCTAssertEqual(line.items.map(\.id), [otherID]); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        }
    }
    @MainActor func testChangedFileBecomesSymlinkAndIsNeverTrashed() throws {
        try fixture { f in
            let line = f.line(), owned = try f.image(), original = try f.image(owned: false)
            let id = try XCTUnwrap(line.hang(owned, quietly: true)); line.select(id); let snapshot = line.trashSelectionSnapshot()
            try FileManager.default.removeItem(at: owned); try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: original)
            XCTAssertEqual(line.trashSelection(snapshot, confirmed: true), 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            XCTAssertTrue((try URL(fileURLWithPath: owned.path).resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
        }
    }
    @MainActor func testExportCollisionsCancelMissingAndSourcesUnchanged() throws {
        try fixture { f in
            let first = try f.image(owned: false, name: "Same.png")
            let second = try f.image(), missing = f.folder.appendingPathComponent("missing.png")
            let folder = f.folder.appendingPathComponent("Export"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = folder.appendingPathComponent("Same.png"); let marker = Data("keep".utf8); try marker.write(to: existing)
            let files = HistoryFiles(inbox: f.inbox, moveToTrash: fixtureTrash(f.folder)), bytes = try Data(contentsOf: first)
            let result = try files.export([(first, "Same.png"), (second, "Same.png"), (missing, "Same.png")], to: folder)
            XCTAssertEqual(result.copies.map(\.lastPathComponent), ["Same (2).png", "Same (3).png"])
            XCTAssertEqual(result.failed, [missing]); XCTAssertEqual(try Data(contentsOf: existing), marker)
            XCTAssertEqual(try Data(contentsOf: first), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
            let line = f.line(); line.hang(first, quietly: true); line.selectAll()
            let before = line.items.count; XCTAssertNil(try line.exportSelected(to: nil)); XCTAssertEqual(line.items.count, before)
            let sameFolder = try files.export([(first, first.lastPathComponent)], to: first.deletingLastPathComponent())
            XCTAssertEqual(sameFolder.copies[0].lastPathComponent, "Same (2).png")
        }
    }
    @MainActor func testKeyboardSelectionCopyPreviewEscapeAndScroll() throws {
        try fixture { f in
            let line = f.line(); line.setViewportWidth(350)
            for _ in 0..<10 { line.hang(try f.image(), quietly: true) }
            var copied: UUID?, previewed: UUID?, closed = 0
            let keyboard = LineKeyboard(line: line, onCopy: { copied = $0 }, onPreview: { previewed = $0 }, onClose: { closed += 1 })
            XCTAssertTrue(keyboard.handle(key(124))); XCTAssertEqual(line.focusedID, line.items[0].id)
            for _ in 0..<6 { _ = keyboard.handle(key(124)) }
            XCTAssertEqual(line.focusedID, line.items[6].id); XCTAssertTrue(line.scrollOffset > 0)
            _ = keyboard.handle(key(124, flags: .shift)); XCTAssertEqual(line.selectedItems.count, 2)
            _ = keyboard.handle(key(36)); _ = keyboard.handle(key(49)); XCTAssertEqual(copied, line.focusedID); XCTAssertEqual(previewed, line.focusedID)
            XCTAssertTrue(keyboard.handle(key(8, flags: .command, text: "c")))
            _ = keyboard.handle(key(53)); XCTAssertEqual(closed, 1); XCTAssertNil(line.focusedID)
        }
    }
    @MainActor func testPanelKeyboardRequiresExplicitFocusAndStopsAfterClose() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView()); var routed = 0
        panel.onKey = { _ in routed += 1; return true }
        panel.sendEvent(key(124)); XCTAssertEqual(routed, 0); XCTAssertFalse(panel.canBecomeKey)
        panel.keyboardFocusAllowed = true
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.routeKey(key(124), isFocused: false)); XCTAssertEqual(routed, 0)
        XCTAssertTrue(panel.routeKey(key(124), isFocused: true)); XCTAssertEqual(routed, 1)
        panel.keyboardFocusAllowed = false
        XCTAssertFalse(panel.routeKey(key(124), isFocused: true)); XCTAssertEqual(routed, 1)
    }
    @MainActor func testShortcutValidationPersistenceAndNoDefaultInterception() throws {
        try fixture { f in
            let line = f.line(); XCTAssertNil(line.copyLatestShortcut)
            XCTAssertNil(KeyShortcut.capture(key(8, text: "c")))
            let custom = try XCTUnwrap(KeyShortcut.capture(key(8, flags: [.command, .shift], text: "c")))
            XCTAssertEqual(custom.title, "⇧⌘C"); line.saveCopyLatestShortcut(custom)
            XCTAssertEqual(f.line().copyLatestShortcut, custom)
            line.saveCopyLatestShortcut(KeyShortcut(keyCode: -1, modifiers: cmdKey, keyLabel: "invalid"))
            XCTAssertEqual(line.copyLatestShortcut, custom)
            line.saveCopyLatestShortcut(nil); XCTAssertNil(f.line().copyLatestShortcut)
            f.defaults.set(Data("bad".utf8), forKey: "copyLatestShortcut"); XCTAssertNil(line.copyLatestShortcut)
        }
    }
    @MainActor func testPasteQueueShortcutIsOffByDefaultAndQueueStaysInSession() throws {
        try fixture { f in
            let line = f.line(); XCTAssertNil(line.pasteQueueShortcut)
            let custom = KeyShortcut(keyCode: 9, modifiers: controlKey | optionKey, keyLabel: "V")
            line.savePasteQueueShortcut(custom); XCTAssertEqual(f.line().pasteQueueShortcut, custom)
            line.savePasteQueueShortcut(nil); XCTAssertNil(f.line().pasteQueueShortcut)
            let newest = UUID(), middle = UUID(), oldest = UUID(); var counts = [Int]()
            line.onPasteQueued = { counts.append($0) }
            line.queueForPaste([]); XCTAssertTrue(line.pasteQueue.isEmpty); XCTAssertTrue(counts.isEmpty)
            line.queueForPaste([newest, middle, oldest])
            XCTAssertEqual(line.pasteQueue, [oldest, middle, newest]); XCTAssertEqual(counts, [3])
            line.completeQueuedPaste(newest); XCTAssertEqual(line.pasteQueue, [oldest, middle, newest])
            line.completeQueuedPaste(oldest); XCTAssertEqual(line.pasteQueue, [middle, newest])
            XCTAssertTrue(f.line().pasteQueue.isEmpty)
        }
    }
    @MainActor func testHotKeysCanCoexistAndConflictsPreserveRegistration() throws {
        let modifiers = controlKey | optionKey | cmdKey
        let first = HotKey(keyCode: kVK_F18, modifiers: modifiers) {}
        let second = HotKey(keyCode: kVK_F19, modifiers: modifiers) {}
        defer { first.invalidate(); second.invalidate() }
        XCTAssertTrue(first.isRegistered); XCTAssertTrue(second.isRegistered)
        let conflict = HotKey(keyCode: kVK_F18, modifiers: modifiers) {}
        XCTAssertFalse(conflict.isRegistered); XCTAssertTrue(first.isRegistered)
        first.invalidate(); XCTAssertFalse(first.isRegistered)
        let replacement = HotKey(keyCode: kVK_F18, modifiers: modifiers) {}; defer { replacement.invalidate() }
        XCTAssertTrue(replacement.isRegistered); XCTAssertTrue(second.isRegistered)
    }
    @MainActor func testHotKeyEventsRouteToTheirOwnCallbackOnly() throws {
        var firstCalls = 0, secondCalls = 0
        let modifiers = controlKey | optionKey | cmdKey
        let first = HotKey(keyCode: kVK_F16, modifiers: modifiers) { firstCalls += 1 }
        let second = HotKey(keyCode: kVK_F17, modifiers: modifiers) { secondCalls += 1 }
        defer { first.invalidate(); second.invalidate() }
        XCTAssertTrue(first.isRegistered); XCTAssertTrue(second.isRegistered)
        for hotKey in [first, second, first] {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                GetCurrentEventTime(), UInt32(kEventAttributeUserEvent), &event), noErr)
            let localEvent = try XCTUnwrap(event)
            var id = EventHotKeyID(signature: 0x5445_4E44, id: hotKey.identifier)
            XCTAssertEqual(SetEventParameter(localEvent, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &id), noErr)
            XCTAssertEqual(SendEventToEventTarget(localEvent, GetApplicationEventTarget()), noErr)
            ReleaseEvent(localEvent)
        }
        let deadline = Date().addingTimeInterval(2)
        while (firstCalls != 2 || secondCalls != 1) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(firstCalls, 2); XCTAssertEqual(secondCalls, 1)
    }
    @MainActor private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}
