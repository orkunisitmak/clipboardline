import AppKit
import SwiftUI
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Exercises SwiftUI's actual conditional representable, rather than mounting
/// the search field by hand. All input stays in-process in an unordered panel.
@MainActor final class ShelfSearchMountedTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool, layout: () -> Void) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline {
            layout()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), "Mounted shelf search did not settle")
    }

    private func fields(in view: NSView) -> [ShelfSearchTextField] {
        (view as? ShelfSearchTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    private func key(_ code: UInt16, _ text: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }

    func testSwiftUIMountedImageSearchKeepsNativeEditorAndFiltersTypedOCR() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let match = try store.captureImage(f.image()), other = try store.captureImage(f.image())
        let note = try XCTUnwrap(store.captureText("Text draft 8427"))
        let link = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/8427")))
        let database = try LibraryDatabase(url: store.databaseURL, verify: false)
        try database.execute("INSERT INTO image_analysis(item,path,fingerprint,version,content,ocr,vectors) VALUES(?,?,?,?,?,?,?)", [
            .text(match.id.uuidString), .text(try XCTUnwrap(match.path)), .text("synthetic"),
            .text("vision-ocr-v1"), .text("mounted ocr 8427"), .text("Mounted OCR 8427"), .blob(Data())
        ])
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        line.setPresentation(.all, requestFocus: false); line.revealed = true
        XCTAssertEqual(Set(line.displayItems.map(\.id)), Set([match.id, other.id]))
        let host = NSHostingView(rootView: LineView(line: line)); host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.keyboardFocusAllowed = true; panel.contentHeight = line.panelHeight
        panel.setFrame(NSRect(x: -10000, y: -10000, width: 1920, height: line.panelHeight), display: false)
        panel.searchEditorTarget = { [weak line] in
            guard let line, let shelf = line.searchEditingShelf else { return nil }
            return ShelfSearchFocus(shelf: shelf, request: line.searchFocusRequests[shelf, default: 0])
        }
        line.onFocusRequested = { [weak panel, weak line] in
            guard let panel, let line else { return }
            panel.keyboardFocusAllowed = true
            if line.searchEditingShelf == nil { panel.makeFirstResponder(nil) }
        }
        defer {
            line.onFocusRequested = nil; line.revealed = false
            panel.makeFirstResponder(nil); panel.contentView = nil
        }
        let layout = { host.layoutSubtreeIfNeeded() }
        layout(); line.beginShelfSearch(.images)
        // Real key events can arrive before SwiftUI mounts its native editor.
        XCTAssertFalse(panel.firstResponder is NSTextView)
        XCTAssertTrue(panel.routeKey(key(28, "8"), isFocused: true))
        XCTAssertEqual(line.shelfSearch?.query(for: .image), "")
        wait({ self.fields(in: host).contains { $0.shelf == .images && $0.bounds.width > 0 && $0.bounds.height > 0 } }, layout: layout)
        let field = try XCTUnwrap(fields(in: host).first { $0.shelf == .images })
        XCTAssertEqual(fields(in: host).count, 1, "Only the active search panel mounts a native editor")
        let rect = field.convert(field.bounds, to: host)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(rect.minX >= 0 && rect.maxX <= host.bounds.width)
        XCTAssertTrue(rect.minY >= 0 && rect.maxY <= host.bounds.height)
        // NSView.hitTest takes a point in its superview's coordinate system.
        // The hosting view is flipped; its AppKit parent need not be.
        let hostParent = try XCTUnwrap(host.superview)
        let fieldCenter = NSPoint(x: field.bounds.midX, y: field.bounds.midY)
        let hitPoint = field.convert(fieldCenter, to: hostParent)
        let hit = host.hitTest(hitPoint)
        XCTAssertTrue(hit === field || hit?.isDescendant(of: field) == true,
            "Mounted native field must receive clicks at its center; hostFlipped=\(host.isFlipped), parentFlipped=\(hostParent.isFlipped), parentPoint=\(hitPoint), hit=\(String(describing: hit))")
        let fieldCenterInWindow = field.convert(fieldCenter, to: nil)
        let localClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: fieldCenterInWindow,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        XCTAssertTrue(localClick.window === panel)
        let clickScreenPoint = AppDelegate.clickScreenPoint(localClick)
        XCTAssertEqual(clickScreenPoint, panel.convertPoint(toScreen: fieldCenterInWindow),
            "Local clicks must use the event position rather than an unrelated global pointer")
        XCTAssertFalse(NSScreen.screens.contains { NSMouseInRect(clickScreenPoint, AppDelegate.menuBarBand(of: $0), false) },
            "A click in the offscreen native search field cannot be a menu-bar dismissal")
        wait({ field.currentEditor() != nil && panel.firstResponder === field.currentEditor() }, layout: layout)
        // Further SwiftUI publications must not immediately evict its editor.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)); layout()
        XCTAssertEqual(line.searchEditingShelf, .images)
        let initialEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(initialEditor.string, "8", "The first key must survive the native editor's mounting interval")
        initialEditor.insertText("427", replacementRange: NSRange(location: NSNotFound, length: 0))
        wait({ line.shelfSearch?.query(for: .image) == "8427" && line.shelfSearch?.isSearching(for: .image) == false }, layout: layout)
        XCTAssertEqual(line.displayItems.map(\.id), [match.id])
        wait({ line.texts.displayEntries.map(\.id) == [note.id] && line.links.displayEntries.map(\.id) == [link.id] }, layout: layout)
        XCTAssertEqual(line.shelfSearchResultCount, 3, "Mounted field searches text, URL and cached OCR together")
        // Queue focus, the first typed character, then duplicate representable
        // updates in that exact order. Late focus callbacks must not select the
        // new character and let the rest of the word replace it (8427 -> 427).
        line.beginShelfSearch(.images)
        field.synchronize()
        var firstCharacterWasTyped = false
        DispatchQueue.main.async {
            if let current = field.currentEditor() as? NSTextView {
                current.insertText("8", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            firstCharacterWasTyped = true
        }
        for _ in 0..<3 { field.synchronize() }
        wait({ firstCharacterWasTyped }, layout: layout)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)); layout()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(editor.string, "8")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0), "Queued focus callbacks must preserve the typing caret")
        editor.insertText("427", replacementRange: NSRange(location: NSNotFound, length: 0))
        wait({ line.shelfSearch?.query(for: .image) == "8427" && line.shelfSearch?.isSearching(for: .image) == false }, layout: layout)
        XCTAssertEqual(line.displayItems.map(\.id), [match.id])
        XCTAssertEqual(field.stringValue, "8427")
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(line.searchEditingShelf, .images)
        // An event waiting for an abandoned focus request must never become
        // text in the next newly opened search session on the same shelf.
        _ = line.closeShelfSearch(.images)
        wait({ self.fields(in: host).isEmpty }, layout: layout)
        line.beginShelfSearch(.images)
        XCTAssertTrue(panel.routeKey(key(25, "9"), isFocused: true))
        _ = line.closeShelfSearch(.images)
        wait({ self.fields(in: host).isEmpty }, layout: layout)
        line.beginShelfSearch(.images)
        wait({ self.fields(in: host).count == 1 && self.fields(in: host).first?.shelf == .images && self.fields(in: host).first?.currentEditor() != nil }, layout: layout)
        let reopened = try XCTUnwrap(fields(in: host).first)
        XCTAssertFalse(reopened === field, "Closing the floating panel destroys its old native editor")
        wait({ panel.firstResponder === reopened.currentEditor() }, layout: layout)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)); layout()
        XCTAssertEqual(line.shelfSearch?.query(for: .image), "")
        XCTAssertEqual(reopened.stringValue, "", "An abandoned request's queued input must be discarded")
        line.updateShelfSearch("8427", for: .images)
        wait({ line.shelfSearch?.isSearching(for: .image) == false && line.displayItems.map(\.id) == [match.id] }, layout: layout)
        let reopenedEditor = try XCTUnwrap(reopened.currentEditor() as? NSTextView)
        XCTAssertTrue(reopened.control(reopened, textView: reopenedEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        wait({ self.fields(in: host).isEmpty }, layout: layout)
        XCTAssertNil(line.searchEditingShelf)
        XCTAssertEqual(line.shelfSearchQuery, "8427", "Browsing hides the floating editor but keeps the shared filter")
        XCTAssertEqual(line.displayItems.map(\.id), [match.id])
        // Reopening the query chip/shortcut restores its draft into a fresh
        // native editor. Changing focus anchors never restores a separate draft.
        line.beginShelfSearch(.images)
        wait({ self.fields(in: host).count == 1 && self.fields(in: host).first?.currentEditor() != nil }, layout: layout)
        let restoredImageField = try XCTUnwrap(fields(in: host).first)
        XCTAssertEqual(restoredImageField.shelf, .images)
        XCTAssertEqual(restoredImageField.stringValue, "8427")
        let imageMousePoint = restoredImageField.convert(NSPoint(x: restoredImageField.bounds.midX, y: restoredImageField.bounds.midY), to: nil)
        panel.prepareSearchMouseFocus(at: imageMousePoint)
        XCTAssertEqual(line.activeShelf, .images)
        XCTAssertEqual(line.searchEditingShelf, .images, "Native field hit testing must identify its owning shelf")
        line.beginShelfSearch(.texts)
        wait({ self.fields(in: host).count == 1 && self.fields(in: host).first?.shelf == .texts && self.fields(in: host).first?.currentEditor() != nil }, layout: layout)
        let textField = try XCTUnwrap(fields(in: host).first { $0.shelf == .texts })
        XCTAssertFalse(textField === restoredImageField)
        XCTAssertFalse(fields(in: host).contains { $0.shelf == .images })
        XCTAssertEqual(line.searchEditingShelf, .texts)
        XCTAssertEqual(textField.stringValue, "8427", "Changing anchor keeps the one shared phrase")
        line.updateShelfSearch("text draft", for: .texts)
        line.beginShelfSearch(.images)
        // The outgoing scope may emit its end notification while SwiftUI
        // replaces the editor; it must not cancel the incoming focus request.
        textField.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: textField))
        XCTAssertEqual(line.searchEditingShelf, .images)
        wait({ self.fields(in: host).count == 1 && self.fields(in: host).first?.shelf == .images && self.fields(in: host).first?.currentEditor() != nil }, layout: layout)
        let imageField = try XCTUnwrap(fields(in: host).first)
        XCTAssertFalse(imageField === textField)
        wait({ panel.firstResponder === imageField.currentEditor() }, layout: layout)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)); layout()
        XCTAssertEqual(line.activeShelf, .images)
        XCTAssertEqual(line.searchEditingShelf, .images)
        XCTAssertTrue(imageField.currentEditor() != nil && panel.firstResponder === imageField.currentEditor())
        XCTAssertEqual(line.shelfSearch?.query(for: .image), "text draft")
        XCTAssertEqual(imageField.stringValue, "text draft", "Reattaching the requested editor must preserve the shared query")
        XCTAssertTrue(line.shelfSearch?.isActive(for: .text) ?? false, "Changing editor focus keeps visible rows in the same search")
        XCTAssertEqual(line.shelfSearch?.query(for: .text), "text draft")
        wait({ line.displayItems.isEmpty && line.texts.displayEntries.map(\.id) == [note.id] && line.links.displayEntries.isEmpty }, layout: layout)
        XCTAssertEqual(line.shelfSearchResultCount, 1)
        // A visibility toggle can remove the current native focus anchor.
        // The replacement editor must keep the common phrase and input focus.
        line.setPresentation(.textsLinks, requestFocus: false)
        wait({
            let mounted = self.fields(in: host)
            return mounted.count == 1 && mounted.first?.shelf == .texts && mounted.first?.currentEditor() != nil && panel.firstResponder === mounted.first?.currentEditor()
        }, layout: layout)
        let retargetedField = try XCTUnwrap(fields(in: host).first)
        XCTAssertFalse(retargetedField === imageField)
        XCTAssertEqual(line.searchEditingShelf, .texts)
        XCTAssertEqual(line.shelfSearchQuery, "text draft")
        XCTAssertEqual(retargetedField.stringValue, "text draft", "Hiding the focus anchor must not replace the shared phrase")
        XCTAssertFalse(line.shelfSearch?.isActive(for: .image) ?? true)
        XCTAssertEqual(line.texts.displayEntries.map(\.id), [note.id])
        XCTAssertEqual(line.shelfSearchResultCount, 1)
        XCTAssertFalse(panel.isVisible, "Native regression must never present a user-facing window")
    }

    func testFloatingSearchPanelCentersAndReceivesClicksAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        for presentation in [ShelfPresentation.images, .all] {
            for width in [CGFloat(320), 1920] {
                let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
                line.setPresentation(presentation, requestFocus: false); line.revealed = true
                let host = NSHostingView(rootView: LineView(line: line)); host.sizingOptions = []
                let panel = LinePanel(content: host)
                panel.keyboardFocusAllowed = true; panel.contentHeight = line.panelHeight
                panel.setFrame(NSRect(x: -10000, y: -10000, width: width, height: line.panelHeight), display: false)
                defer {
                    line.revealed = false; panel.makeFirstResponder(nil); panel.contentView = nil
                }
                let layout = { host.layoutSubtreeIfNeeded() }
                layout(); line.beginShelfSearch(.images)
                wait({ self.fields(in: host).count == 1 && line.hitRects[LineView.searchPanelID] != nil }, layout: layout)
                let field = try XCTUnwrap(fields(in: host).first)
                let panelRect = try XCTUnwrap(line.hitRects[LineView.searchPanelID])
                let inputRect = field.convert(field.bounds, to: host)
                XCTAssertTrue(abs(panelRect.midX - host.bounds.midX) <= 1, "Search must stay horizontally centered at width \(width)")
                XCTAssertTrue(abs(panelRect.midY - host.bounds.midY) <= 1, "Search must appear between the visible shelves")
                XCTAssertTrue(panelRect.minX >= 0 && panelRect.maxX <= host.bounds.width, "Search panel must fit narrow windows")
                XCTAssertTrue(panelRect.minY >= 0 && panelRect.maxY <= host.bounds.height)
                XCTAssertTrue(panelRect.contains(inputRect), "The native editor must remain within the panel's mouse-interactive region")
                XCTAssertTrue(inputRect.width >= 80 && inputRect.height >= 24)
                XCTAssertFalse(field.isBordered, "The floating panel supplies the input boundary")
                XCTAssertFalse(field.drawsBackground, "The native field must not add a second search surface")
                let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: host.superview)
                let hit = host.hitTest(center)
                XCTAssertTrue(hit === field || hit?.isDescendant(of: field) == true, "Centered search must receive input rather than a shelf card underneath")
                XCTAssertFalse(panel.isVisible, "Layout validation must not present a user-facing window")
            }
        }
    }

    /// The shelf window can be made again while search is being typed into
    /// (AppDelegate.keepPanelOnActiveSpace). Keys the old window accepted, and
    /// keys typed before the new window has an editor, reach the field in
    /// order, and the caret stays where it was.
    func testReplacedShelfWindowKeepsSearchEditorQueuedKeysAndCaret() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        line.setPresentation(.all, requestFocus: false); line.revealed = true
        let host = NSHostingView(rootView: LineView(line: line)); host.sizingOptions = []
        var panel = LinePanel(content: host), panels = [panel]
        panel.keyboardFocusAllowed = true; panel.contentHeight = line.panelHeight
        panel.setFrame(NSRect(x: -10000, y: -10000, width: 1920, height: line.panelHeight), display: false)
        panel.searchEditorTarget = { [weak line] in
            guard let line, let shelf = line.searchEditingShelf else { return nil }
            return ShelfSearchFocus(shelf: shelf, request: line.searchFocusRequests[shelf, default: 0])
        }
        defer {
            line.revealed = false
            for window in panels { window.makeFirstResponder(nil); window.contentView = nil }
        }
        let layout = { host.layoutSubtreeIfNeeded() }
        func editor() -> NSTextView? {
            guard let field = fields(in: host).first, field.window === panel,
                  let editor = field.currentEditor() as? NSTextView, panel.firstResponder === editor else { return nil }
            return editor
        }

        layout(); line.beginShelfSearch(.images)
        XCTAssertTrue(panel.routeKey(key(28, "8"), isFocused: true), "Accepted before SwiftUI mounts the field")
        panel = panel.makeReplacement(); panels.append(panel)
        wait({ editor() != nil }, layout: layout)
        XCTAssertEqual(editor()?.string, "8", "A key the old window accepted reaches the field in the new one")

        editor()?.insertText("427", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor()?.setSelectedRange(NSRange(location: 1, length: 0))
        panel = panel.makeReplacement(); panels.append(panel)
        XCTAssertNil(editor(), "The field editor stays with the old window")
        XCTAssertEqual(line.searchEditingShelf, .images, "Search is still being edited")
        XCTAssertTrue(panel.routeKey(key(29, "0"), isFocused: true), "Typing before the editor returns waits for it")
        wait({ editor() != nil }, layout: layout)
        let restored = try XCTUnwrap(editor())
        XCTAssertEqual(restored.string, "80427", "The waiting key lands at the caret, not over a selected query")
        XCTAssertEqual(restored.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertFalse(panel.routeKey(key(7, "x"), isFocused: true), "The native editor owns typing again")
        wait({ line.shelfSearchQuery == "80427" }, layout: layout)
        XCTAssertEqual(line.searchEditingShelf, .images)
    }
}
