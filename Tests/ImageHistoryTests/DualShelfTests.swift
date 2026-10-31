import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

final class DualShelfTests: HistoryTestCase {
    @MainActor private func fixture(_ body: (SyntheticFixture) throws -> Void) throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }; try body(f)
    }
    @MainActor private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    @MainActor func testShelfModesPersistAndTabPreservesBothSelections() throws {
        try fixture { f in
            let line = f.line(); line.hang(try f.image(), quietly: true); line.texts.add("synthetic")
            line.selectAll(); line.texts.selectAll()
            let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
            XCTAssertTrue(keyboard.handle(key(48))); XCTAssertEqual(line.presentation, .texts)
            XCTAssertEqual(f.line().presentation, .texts)
            XCTAssertTrue(keyboard.handle(key(11, flags: [.command, .shift], text: "b")))
            XCTAssertEqual(line.presentation, .both); XCTAssertEqual(line.panelHeight, Layout.panelHeight * 2)
            _ = keyboard.handle(key(48)); XCTAssertEqual(line.activeShelf, .images); XCTAssertEqual(line.presentation, .both)
            XCTAssertEqual(line.selectedItems.count, 1); XCTAssertEqual(line.texts.selectedEntries.count, 1)
            line.toggleBothShelves(); XCTAssertEqual(line.presentation, .images)
            f.defaults.set("invalid", forKey: "shelfPresentation"); XCTAssertEqual(f.line().presentation, .images)
        }
    }
    @MainActor func testShiftArrowsAndEnterCopyEverySelectedImageInOrder() throws {
        try fixture { f in
            var copies: [URL] = []
            let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                moveToTrash: fixtureTrash(f.folder), copyImage: { copies.append($0) }, copyText: { _ in })
            for _ in 0..<5 { line.hang(try f.image(), quietly: true) }
            let keyboard = LineKeyboard(line: line, onCopy: { _ in line.copySelection() }, onPreview: { _ in }, onClose: {})
            _ = keyboard.handle(key(124)); _ = keyboard.handle(key(124, flags: .shift)); _ = keyboard.handle(key(124, flags: .shift))
            _ = keyboard.handle(key(36)); XCTAssertEqual(copies, Array(line.displayItems.prefix(3)).map(\.url))
            copies.removeAll(); _ = keyboard.handle(key(8, flags: .command, text: "c")); XCTAssertEqual(copies.count, 3)
            _ = keyboard.handle(key(123, flags: .shift)); XCTAssertEqual(line.selectedItems.count, 2)
        }
    }
    @MainActor func testTextRangeEnterCommandAAndDeleteAreSymmetric() throws {
        try fixture { f in
            var copied = ""; var trashed: [UUID] = []
            let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                moveToTrash: fixtureTrash(f.folder), copyImage: { _ in }, copyText: { copied = $0 })
            for i in 0..<5 { line.texts.add("Synthetic \(i) 👋\nSecond line") }
            line.setPresentation(.texts, requestFocus: false)
            line.onTrashRequested = { trashed = line.texts.selectedEntries.map(\.id); line.texts.trash(trashed) }
            let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {}, onTextCopy: { _ in line.texts.copySelection() })
            _ = keyboard.handle(key(124)); _ = keyboard.handle(key(124, flags: .shift)); _ = keyboard.handle(key(124, flags: .shift))
            _ = keyboard.handle(key(36))
            XCTAssertEqual(copied, line.texts.displayEntries.prefix(3).map(\.text).joined(separator: "\n\n"))
            _ = keyboard.handle(key(0, flags: .command, text: "a")); XCTAssertEqual(line.texts.selectedEntries.count, 5)
            _ = keyboard.handle(key(117)); XCTAssertEqual(trashed.count, 5); XCTAssertTrue(line.texts.entries.isEmpty)
            XCTAssertTrue(line.texts.selectedEntries.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.folder.appendingPathComponent(".test-trash").path).count, 5)
        }
    }
    @MainActor func testPinKeyOnAMixedShelfSelectionPinsEveryItemAndOnlyAFullyPinnedSelectionUnpins() throws {
        try fixture { f in
            let line = f.line()
            for i in 0..<3 { line.texts.add("Synthetic \(i)") }
            let image = try XCTUnwrap(line.hang(try f.image(), quietly: true)); _ = line.hang(try f.image(), quietly: true)
            line.texts.togglePin(line.texts.entries[0].id); try line.togglePin(image)
            let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
            line.selectAll(); _ = keyboard.handle(key(35, text: "p"))
            XCTAssertEqual(line.items.map(\.pinned), [true, true])
            line.setPresentation(.texts, requestFocus: false); line.texts.selectAll(); _ = keyboard.handle(key(35, text: "p"))
            XCTAssertEqual(line.texts.entries.map(\.pinned), [true, true, true])
            _ = keyboard.handle(key(35, text: "p"))
            XCTAssertEqual(line.texts.entries.map(\.pinned), [false, false, false])
        }
    }
    @MainActor func testDeselectingFocusedItemStillCopiesOnlyRemainingSelection() throws {
        try fixture { f in
            var copies: [URL] = []; var text = ""
            let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                moveToTrash: fixtureTrash(f.folder), copyImage: { copies.append($0) }, copyText: { text = $0 })
            for _ in 0..<3 { line.hang(try f.image(), quietly: true) }
            line.selectAll(); line.select(line.items[0].id, toggle: true); line.copySelection()
            XCTAssertEqual(copies, Array(line.items.dropFirst()).map(\.url))
            for i in 0..<3 { line.texts.add("synthetic \(i)") }; line.texts.selectAll()
            line.texts.select(line.texts.entries[0].id, toggle: true, width: 1000); line.texts.copySelection()
            XCTAssertEqual(text, line.texts.entries.dropFirst().map(\.text).joined(separator:"\n\n"))
            line.cancelSelection(); copies.removeAll(); line.copySelection(); XCTAssertTrue(copies.isEmpty)
        }
    }
    @MainActor func testOnlyPlainReturnUsesShelfCopyAndCloseWhileOtherCopyAndEditingRoutesStayOpen() throws {
        _ = NSApplication.shared
        try fixture { f in
            let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
            _ = try store.captureImage(f.image())
            _ = try store.captureText("Synthetic copy and close note")
            _ = try store.captureLink(URL(string: "https://example.com/copy-and-close")!)
            var writes = 0, confirmed = 0, legacyCopies = 0, closes = 0
            let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                copyImage: { _ in writes += 1 }, copyText: { _ in writes += 1 }, library: store)
            let keyboard = LineKeyboard(line: line, onCopy: { _ in legacyCopies += 1 }, onPreview: { _ in },
                onClose: { closes += 1 }, onTextCopy: { _ in legacyCopies += 1 },
                onCopyAndClose: { confirmed += 1; XCTAssertTrue(line.copySelection()) })
            for shelf in Shelf.allCases {
                line.focusShelf(shelf, requestFocus: false); line.selectAllActive()
                XCTAssertTrue(keyboard.handle(key(36)))
                XCTAssertTrue(keyboard.handle(key(76)))
            }
            XCTAssertEqual(confirmed, 6); XCTAssertEqual(writes, 6); XCTAssertEqual(legacyCopies, 0)
            XCTAssertTrue(keyboard.handle(key(8, flags: .command, text: "c")))
            XCTAssertTrue(keyboard.perform(.copy))
            XCTAssertEqual(writes, 8); XCTAssertEqual(confirmed, 6); XCTAssertEqual(closes, 0)
            var pasted = [UUID](); line.onPasteRequested = { pasted = $0 }
            XCTAssertTrue(keyboard.handle(key(36, flags: .command)))
            XCTAssertEqual(pasted, line.activeActionIDs); XCTAssertFalse(pasted.isEmpty)
            XCTAssertEqual(confirmed, 6); XCTAssertEqual(writes, 8)

            line.beginShelfSearch()
            XCTAssertFalse(keyboard.handle(key(36))); XCTAssertFalse(keyboard.handle(key(76)))
            XCTAssertEqual(confirmed, 6, "Return in the native search field must not dismiss browsing")
            XCTAssertTrue(line.closeShelfSearch(requestFocus: false))
            let preview = TextPreview(text: "Synthetic editable note", keyboardBindings: line.keyboardBindings)
            defer { preview.window.close() }
            preview.onKey = { keyboard.handle($0) }; preview.beginEditing()
            XCTAssertFalse(preview.routeKey(key(36))); XCTAssertFalse(preview.routeKey(key(76)))
            XCTAssertTrue(preview.isEditing); XCTAssertEqual(confirmed, 6)
        }
    }
    @MainActor func testShelfCopyReportsSuccessOnlyAfterCopyingNonemptyImageTextAndLinkBatches() throws {
        try fixture { f in
            let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
            for i in 0..<2 {
                _ = try store.captureImage(f.image())
                _ = try store.captureText("Synthetic batch note \(i)")
                _ = try store.captureLink(URL(string: "https://example.com/batch/\(i)")!)
                f.date.addTimeInterval(1)
            }
            var copiedImages = [URL](), copiedText = [String]()
            let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                copyImage: { copiedImages.append($0) }, copyText: { copiedText.append($0) }, library: store)
            for shelf in Shelf.allCases {
                line.focusShelf(shelf, requestFocus: false)
                copiedImages.removeAll(); copiedText.removeAll()
                XCTAssertFalse(line.copySelection(), "An empty selection cannot dismiss the shelf")
                line.selectAllActive()
                line.onFlushPreview = { false }
                XCTAssertFalse(line.copySelection(), "A failed edit save must keep the shelf open")
                XCTAssertTrue(copiedImages.isEmpty); XCTAssertTrue(copiedText.isEmpty)
                line.onFlushPreview = { true }
                XCTAssertTrue(line.copySelection())
                switch shelf {
                case .images: XCTAssertEqual(copiedImages, line.selectedItems.map(\.url))
                case .texts: XCTAssertEqual(copiedText, [line.texts.selectedEntries.map(\.text).joined(separator: "\n\n")])
                case .links: XCTAssertEqual(copiedText, [line.links.selectedEntries.compactMap(\.originalURL).joined(separator: "\n\n")])
                }
                XCTAssertEqual(line.activeActionIDs.count, 2, "Copying must finish before dismissal clears the batch")
            }

            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            XCTAssertTrue(line.copyItems(line.selectedItems, to: board))
            XCTAssertEqual(board.pasteboardItems?.compactMap { $0.data(forType: .png) }.count, 2)
            XCTAssertTrue(line.texts.copyEntries(line.texts.selectedEntries, to: board))
            XCTAssertEqual(board.string(forType: .string), line.texts.selectedEntries.map(\.text).joined(separator: "\n\n"))
            XCTAssertTrue(line.links.copyEntries(line.links.selectedEntries, to: board))
            XCTAssertEqual(board.string(forType: .string), line.links.selectedEntries.compactMap(\.originalURL).joined(separator: "\n\n"))
            let previousChange = board.changeCount
            XCTAssertFalse(line.texts.copyEntries([], to: board)); XCTAssertFalse(line.links.copyEntries([], to: board))
            let broken = f.line(), missing = try f.image()
            broken.hang(missing, quietly: true); broken.selectAll()
            try FileManager.default.removeItem(at: missing)
            XCTAssertFalse(broken.copyItems(broken.selectedItems, to: board))
            XCTAssertEqual(board.changeCount, previousChange, "Failed copying must preserve the existing pasteboard")
        }
    }
    @MainActor func testNamedPasteboardContainsEveryImageAndFinderFileURL() throws {
        try fixture { f in
            let urls = try (0..<3).map { _ in try f.image() }
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(ClipboardTransfer.write(try ClipboardTransfer.imageItems(urls), to: pasteboard))
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 3)
            XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
            XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.data(forType: .png) }.count, 3)
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
            XCTAssertEqual(objects?.map(\.path), urls.map(\.path))
            XCTAssertEqual((pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.count, 3)
        }
    }
    @MainActor func testFailedTransferLeavesNamedPasteboardAndOriginalsUntouched() throws {
        try fixture { f in
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            pasteboard.setString("synthetic sentinel", forType: .string)
            let url = try f.image(), bytes = try Data(contentsOf: url); let change = pasteboard.changeCount
            var rejected = false
            do { _ = try ClipboardTransfer.imageItems([url, f.folder.appendingPathComponent("missing.png")]) } catch { rejected = true }
            XCTAssertTrue(rejected); XCTAssertEqual(pasteboard.changeCount, change)
            XCTAssertEqual(pasteboard.string(forType: .string), "synthetic sentinel"); XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(ClipboardTransfer.write([], to: pasteboard)); XCTAssertEqual(pasteboard.changeCount, change)
        }
    }
    @MainActor func testTextPasteboardConcatenatesAllEntriesAndDragOffersAllFiles() throws {
        try fixture { f in
            let texts = f.texts(); for i in 0..<3 { texts.add("Text \(i) 🌍\nLine two") }; texts.selectAll()
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            texts.copyEntries(texts.selectedEntries, to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), texts.entries.map(\.text).joined(separator: "\n\n"))
            let values = texts.dragItems(texts.entries[1].id)
            XCTAssertEqual(values.map(\.id), texts.selectedEntries.map(\.id)); XCTAssertEqual(values.count, 3)
            XCTAssertEqual(GrabView(frame: NSRect(x: 0, y: 0, width: 140, height: 100)).draggingItems(for: values).count, 3)
            pasteboard.clearContents(); XCTAssertTrue(pasteboard.writeObjects(values.map(\.writer)))
            XCTAssertEqual(pasteboard.string(forType: .string), texts.entries.map(\.text).joined(separator: "\n\n"))
            XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }.count, 3)
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)); editor.isRichText = false
            XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
            XCTAssertEqual(editor.string, texts.entries.map(\.text).joined(separator: "\n\n"))
            for (value, entry) in zip(values, texts.selectedEntries) {
                XCTAssertEqual(try String(contentsOf: value.sourceURL, encoding: .utf8), entry.text)
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: value.sourceURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            texts.trash(values.map(\.id)); XCTAssertTrue(texts.entries.isEmpty)
        }
    }
    @MainActor func testImageDragSnapshotIncludesSelectionAndUnselectedDragIsSingle() throws {
        try fixture { f in
            let line = f.line(); for _ in 0..<5 { line.hang(try f.image(), quietly: true) }
            line.select(line.items[0].id); line.select(line.items[2].id, extending: true)
            let values = line.dragItems(line.items[1].id)
            XCTAssertEqual(values.map(\.sourceURL), line.selectedItems.map(\.url))
            XCTAssertEqual(GrabView(frame: NSRect(x: 0, y: 0, width: 140, height: 100)).draggingItems(for: values).count, 3)
            line.select(line.items[4].id)
            XCTAssertEqual(values.count, 3); XCTAssertEqual(line.dragItems(line.items[3].id).count, 1)
            let snapshot = Line.TrashSelection(images: line.items.filter { image in values.contains { $0.id == image.id } }, appCopies: 3)
            XCTAssertEqual(line.trashSelection(snapshot, confirmed: true), 3); XCTAssertEqual(line.items.count, 2)
            XCTAssertEqual(line.focusedID, line.items[1].id)
        }
    }
    @MainActor func testTextDragRefusesSymlinkWithoutOverwritingTarget() throws {
        try fixture { f in
            let texts = f.texts(); texts.add("synthetic private text"); let entry = texts.entries[0]
            let original = f.folder.appendingPathComponent("original.txt"); let marker = Data("keep synthetic target".utf8); try marker.write(to: original)
            let target = texts.folder.appendingPathComponent("Text \(entry.id).txt")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            XCTAssertTrue(texts.dragItems(entry.id).isEmpty)
            XCTAssertEqual(try Data(contentsOf: original), marker); XCTAssertEqual(texts.entries.count, 1)
        }
    }
    @MainActor func testBorderlessPreviewHasNoFooterAndCannotZoomBelowFit() throws {
        try fixture { f in
            let preview = try XCTUnwrap(ImagePreview(url: try f.image()))
            XCTAssertFalse(preview.window.styleMask.contains(.titled)); XCTAssertTrue(preview.window.canBecomeKey)
            XCTAssertFalse(preview.window.hidesOnDeactivate); XCTAssertEqual(preview.scroll.fittedSize, preview.window.frame.size)
            XCTAssertEqual(preview.scroll.documentView?.frame.size, preview.scroll.fittedSize)
            XCTAssertEqual(preview.scroll.superview, preview.window.contentView)
            XCTAssertEqual(preview.scroll.frame, preview.window.contentView?.bounds)
            XCTAssertTrue(preview.toolbar.isHidden)
            let down = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -100, wheel2: 0, wheel3: 0))
            preview.scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: down)))
            XCTAssertEqual(preview.scroll.zoom.scale, 1); XCTAssertEqual(preview.scroll.documentView?.frame.size, preview.scroll.fittedSize)
        }
    }
    @MainActor func testPanelHeightKeepsBothRowsInsideVisibleScreen() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView()); panel.contentHeight = Layout.panelHeight * 2
        let screen = try XCTUnwrap(LinePanel.screenUnderPointer()); panel.placeOnScreen(screen)
        XCTAssertEqual(panel.frame.height, Layout.panelHeight * 2)
        XCTAssertEqual(panel.frame.maxY, screen.visibleFrame.maxY)
    }
}
