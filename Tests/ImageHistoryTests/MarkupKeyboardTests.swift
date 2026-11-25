import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class MarkupKeyboardTests: HistoryTestCase {
    private func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }

    func testMarkupToggleIsImageOnlyAndToolsHaveSeparateContext() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        for context in KeyboardContext.allCases {
            XCTAssertEqual(bindings.action(for: key(46, "m"), in: context),
                           [.line, .imagePreview, .imageMarkup, .library].contains(context) ? .markup : nil)
        }
        let tools: [(UInt16, String, KeyboardAction)] = [(9,"v",.markupSelect), (11,"b",.markupPen),
            (4,"h",.markupMarker), (15,"r",.markupRectangle), (31,"o",.markupEllipse),
            (0,"a",.markupArrow), (2,"d",.markupLine), (17,"t",.markupText)]
        for (code, text, action) in tools {
            XCTAssertEqual(bindings.action(for: key(code, text), in: .imageMarkup), action)
            XCTAssertEqual(action.contexts, [.imageMarkup])
            XCTAssertNil(bindings.action(for: key(code, text), in: .imagePreview))
            XCTAssertNil(bindings.action(for: key(code, text), in: .textPreview))
            XCTAssertNil(bindings.action(for: key(code, text), in: .linkPreview))
        }
        XCTAssertEqual(bindings.action(for: key(35,"p"), in: .imagePreview), .pin)
        XCTAssertNil(bindings.action(for: key(35,"p"), in: .imageMarkup))
    }

    func testShelfMarkupUsesFocusedImageAndRespectsSearchNativeEditorsAndRemapping() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let first = try store.captureImage(f.image()); f.date += 1
        _ = try store.captureImage(f.image()); _ = try store.captureText("Synthetic note")
        _ = try store.captureLink(URL(string: "https://example.com/marker")!)
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                        copyImage: { _ in }, copyText: { _ in }, library: store)
        line.setPresentation(.all, requestFocus: false); line.revealed = true
        var requests = [UUID]()
        line.onImageMarkupRequested = { requests.append($0) }
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
        line.select(first.id)
        XCTAssertTrue(keyboard.handle(key(46, "m"))); XCTAssertEqual(requests, [first.id])
        line.beginShelfSearch()
        XCTAssertFalse(keyboard.handle(key(46, "m"))); XCTAssertEqual(requests.count, 1)
        _ = line.closeShelfSearch()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let panel = LinePanel(content: content); defer { panel.close() }
        panel.keyboardFocusAllowed = true; panel.onKey = keyboard.handle
        for label in ["Search", "Note", "Rename"] {
            let editor = NSTextView(frame: content.bounds); editor.setAccessibilityLabel(label)
            content.addSubview(editor); XCTAssertTrue(panel.makeFirstResponder(editor))
            XCTAssertFalse(panel.routeKey(key(46, "m"), isFocused: true), label)
            editor.insertText("m", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(editor.string, "m"); XCTAssertEqual(requests.count, 1)
            panel.makeFirstResponder(nil); editor.removeFromSuperview()
        }
        for shelf in [Shelf.texts, .links] {
            line.focusShelf(shelf, requestFocus: false)
            XCTAssertTrue(keyboard.handle(key(46, "m"))); XCTAssertEqual(requests.count, 1)
        }
        line.focusShelf(.images, requestFocus: false); line.select(first.id)
        try line.keyboardBindings.set([KeyShortcut(keyCode: 7, modifiers: 0, keyLabel: "X")], for: .markup)
        XCTAssertFalse(keyboard.handle(key(46, "m")))
        XCTAssertTrue(keyboard.handle(key(7, "x"))); XCTAssertEqual(requests, [first.id, first.id])
        try line.keyboardBindings.set([], for: .markup)
        XCTAssertFalse(keyboard.handle(key(7, "x")))
    }

    func testMarkupShortcutsPersistAndDisableWithoutChangingBrowsingKeys() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        try bindings.set([KeyShortcut(keyCode: 35, modifiers: 0, keyLabel: "P")], for: .markupPen)
        let reloaded = KeyboardBindings(defaults: f.defaults)
        XCTAssertEqual(reloaded.action(for: key(35,"p"), in: .imageMarkup), .markupPen)
        XCTAssertEqual(reloaded.action(for: key(35,"p"), in: .imagePreview), .pin)
        XCTAssertEqual(reloaded.action(for: key(35,"p"), in: .line), .pin)
        XCTAssertNil(reloaded.action(for: key(11,"b"), in: .imageMarkup))
        try bindings.set([], for: .markupPen)
        XCTAssertNil(reloaded.action(for: key(35,"p"), in: .imageMarkup))
        try bindings.reset(.markupPen)
        XCTAssertEqual(reloaded.action(for: key(11,"b"), in: .imageMarkup), .markupPen)
    }

    func testMarkupToolConflictsAreRejectedIncludingToggleAndTransferKeys() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        for shortcut in [KeyShortcut(keyCode: 4, modifiers: 0, keyLabel: "H"),
                         KeyShortcut(keyCode: 46, modifiers: 0, keyLabel: "M"),
                         KeyShortcut(keyCode: 8, modifiers: cmdKey, keyLabel: "C")] {
            var rejected = false
            do { try bindings.set([shortcut], for: .markupPen) } catch { rejected = true }
            XCTAssertTrue(rejected)
            XCTAssertEqual(bindings.shortcuts(.markupPen), KeyboardAction.markupPen.defaults)
        }
        try bindings.set([], for: .markupMarker)
        try bindings.set([KeyShortcut(keyCode: 4, modifiers: 0, keyLabel: "H")], for: .markupPen)
        var rejected = false
        do { try bindings.reset(.markupMarker) } catch { rejected = true }
        XCTAssertTrue(rejected)
        XCTAssertTrue(bindings.shortcuts(.markupMarker).isEmpty)
    }

    func testToolbarSelectionRefreshIsSilentAndUserActionsUseCallbacks() throws {
        _ = NSApplication.shared
        let toolbar = ImageMarkupToolbar()
        var calls = 0
        toolbar.onTool = { _ in calls += 1 }; toolbar.onColor = { _ in calls += 1 }
        toolbar.onWidth = { _ in calls += 1 }; toolbar.onFill = { _ in calls += 1 }
        toolbar.update(tool: .ellipse, color: .blue, width: 0.008, fill: true,
                       canUndo: true, canRedo: false, hasSelection: true, status: "saved")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(toolbar.toolButtons[.ellipse]?.state, .on)
        XCTAssertEqual(toolbar.toolButtons[.pen]?.state, .off)
        XCTAssertEqual(toolbar.widthPicker.indexOfSelectedItem, 2)
        XCTAssertEqual(toolbar.fillButton.state, .on)
        XCTAssertEqual(toolbar.statusLabel.stringValue, "saved")
        toolbar.toolButtons[.marker]?.performClick(nil)
        XCTAssertEqual(calls, 1)
        toolbar.update(tool: .marker, color: .blue, width: 0.008, fill: true,
                       canUndo: false, canRedo: false, hasSelection: false, status: "")
        XCTAssertFalse(toolbar.fillButton.isEnabled)
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        try bindings.set([KeyShortcut(keyCode: 35, modifiers: 0, keyLabel: "P")], for: .markupPen)
        toolbar.refreshKeyHints(bindings)
        XCTAssertTrue(toolbar.toolButtons[.pen]?.toolTip?.contains("P") == true)
        try bindings.set([], for: .markupPen); toolbar.refreshKeyHints(bindings)
        XCTAssertEqual(toolbar.toolButtons[.pen]?.toolTip, KeyboardAction.markupPen.title)
    }
}
