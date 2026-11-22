import AppKit
import QuartzCore
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor private final class PreviewMouseDeliveryControl: NSView {
    var received = [NSEvent.EventType]()
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { received.append(event.type) }
    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func mouseUp(with event: NSEvent) { received.append(event.type) }
}

@MainActor final class ImageMarkupInteractionTests: HistoryTestCase {
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "", type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    private func mouse(_ type: NSEvent.EventType, in canvas: ImageMarkupCanvas, at point: NSPoint,
                       flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func drag(_ canvas: ImageMarkupCanvas, from start: NSPoint, to end: NSPoint, flags: NSEvent.ModifierFlags = [], through middle: NSPoint? = nil) {
        canvas.mouseDown(with: mouse(.leftMouseDown, in: canvas, at: start, flags: flags))
        if let middle { canvas.mouseDragged(with: mouse(.leftMouseDragged, in: canvas, at: middle, flags: flags)) }
        canvas.mouseDragged(with: mouse(.leftMouseDragged, in: canvas, at: end, flags: flags))
        canvas.mouseUp(with: mouse(.leftMouseUp, in: canvas, at: end, flags: flags))
    }
    private func click(_ canvas: ImageMarkupCanvas, at point: NSPoint, clicks: Int = 1) {
        canvas.mouseDown(with: mouse(.leftMouseDown, in: canvas, at: point, clicks: clicks))
        canvas.mouseUp(with: mouse(.leftMouseUp, in: canvas, at: point, clicks: clicks))
    }
    private func withCanvas(_ body: (ImageMarkupCanvas) throws -> Void) rethrows {
        _ = NSApplication.shared
        let canvas = ImageMarkupCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.isMarkupEditing = true
        defer { window.close() }; try body(canvas)
    }
    private func image(_ f: SyntheticFixture, name: String? = nil) throws -> URL {
        let url = try f.image(name: name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = bitmap.bitmapData { memset(bytes, 255, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url); return url
    }
    private func stroke(_ preview: ImagePreview, tool: ImageMarkupTool = .ellipse) {
        preview.beginMarkup(); preview.canvas.setTool(tool)
        let bounds = preview.canvas.bounds
        drag(preview.canvas, from: NSPoint(x: bounds.width * 0.2, y: bounds.height * 0.25),
             to: NSPoint(x: bounds.width * 0.7, y: bounds.height * 0.75))
    }
    private func wait(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Markup interaction fixture did not settle")
    }
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
    private func libraryStroke(_ controller: LibraryWindowController, tool: ImageMarkupTool = .ellipse) throws -> ImageMarkupCanvas {
        let window = try XCTUnwrap(controller.previewWindow)
        let canvas = try XCTUnwrap(descendant(ImageMarkupCanvas.self, in: window.contentView))
        if !canvas.isMarkupEditing { try XCTUnwrap(descendant(PreviewControls.self, in: window.contentView)).onMarkup() }
        XCTAssertTrue(canvas.isMarkupEditing); canvas.setTool(tool)
        let bounds = canvas.bounds
        drag(canvas, from: NSPoint(x: bounds.width * 0.2, y: bounds.height * 0.2),
             to: NSPoint(x: bounds.width * 0.8, y: bounds.height * 0.8))
        return canvas
    }

    func testPreviewWindowMouseDeliveryControl() throws {
        _ = NSApplication.shared
        let panel = makePreviewPanel(size: NSSize(width: 400, height: 240), reusing: nil)
        panel.isReleasedWhenClosed = false
        let control = PreviewMouseDeliveryControl(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        panel.contentView = control
        defer { panel.close() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(control)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        print("Preview mouse control: key=\(panel.isKeyWindow), received types=\(control.received.map(\.rawValue))")
        XCTAssertEqual(control.received, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    func testPreviewWindowMarkerDragRecordsAndRenders() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(f), keyboardBindings: KeyboardBindings(defaults: f.defaults)))
        preview.onSaveMarkup = { _ in true }; defer { preview.requestClose() }
        preview.controls.update(position: "1/157", pinned: false)
        preview.show()
        preview.window.sendEvent(key(46, text: "m"))
        preview.window.sendEvent(key(4, text: "h"))
        let canvas = preview.canvas, window = preview.window
        window.contentView?.layoutSubtreeIfNeeded()
        let bounds = canvas.bounds
        let start = NSPoint(x: bounds.width * 0.2, y: bounds.height * 0.4)
        let end = NSPoint(x: bounds.width * 0.8, y: bounds.height * 0.6)
        let root = try XCTUnwrap(window.contentView)
        let hit = root.hitTest(root.convert(start, from: canvas))
        print("Preview mouse delivery: key=\(window.isKeyWindow), canvas hit=\(hit === canvas), accepts first mouse=\(canvas.acceptsFirstMouse(for: nil)), canvas=\(canvas.frame), viewport=\(preview.scroll.frame)")
        XCTAssertTrue(window.canBecomeKey); XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(preview.isMarkupEditing); XCTAssertTrue(canvas.isMarkupEditing)
        XCTAssertEqual(canvas.tool, .marker); XCTAssertEqual(preview.toolbar.toolButtons[.marker]?.state, .on)
        XCTAssertFalse(window.isMovableByWindowBackground); XCTAssertFalse(canvas.mouseDownCanMoveWindow)
        XCTAssertTrue(hit === canvas)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            window.sendEvent(mouse(type, in: canvas, at: point))
        }
        let mark = try XCTUnwrap(preview.document.elements.first)
        XCTAssertEqual(mark.tool, .marker)
        XCTAssertEqual(mark.points.first?.x ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(mark.points.last?.y ?? -1, 0.6, accuracy: 0.001)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func display(_ layer: CALayer) {
            layer.displayIfNeeded(); layer.sublayers?.forEach(display)
        }
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
        let layer = try XCTUnwrap(canvas.layer)
        display(layer); CATransaction.flush(); layer.render(in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let at = Int(bounds.height * 0.5) * context.bytesPerRow + Int(bounds.width * 0.5) * 4
        XCTAssertGreaterThan(bytes[at], 220)
        XCTAssertGreaterThan(bytes[at + 1], 220)
        XCTAssertLessThan(bytes[at + 2], 230, "The yellow marker must appear above the white image")
        // The click policy is confined to editing; leaving markup restores the
        // existing browsing/window-drag path instead of changing all previews.
        window.sendEvent(key(53))
        XCTAssertFalse(preview.isMarkupEditing)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(canvas.mouseDownCanMoveWindow)
    }

    func testShelfMOpensFocusedPhotoAndMarkerDragPersistsAfterEscape() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f))
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
                        copyImage: { _ in }, copyText: { _ in }, library: store)
        line.setPresentation(.images, requestFocus: false); line.revealed = true
        let app = AppDelegate(line: line, watchesFiles: false)
        // The same preview entry point used by the shelf's long-press action.
        line.onImageMarkupRequested = { id in app.showPreview(id); app.preview?.beginMarkup() }
        defer { app.preview?.requestClose() }
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { app.showPreview($0) }, onClose: {})
        XCTAssertEqual(line.focusedID, record.id)
        XCTAssertTrue(keyboard.handle(key(46, text: "m")))
        let preview = try XCTUnwrap(app.preview, "M must open markup directly from the shelf")
        XCTAssertTrue(preview.isMarkupEditing)
        XCTAssertTrue(preview.routeKey(key(4, text: "h")))
        let canvas = preview.canvas, bounds = preview.canvas.bounds
        let start = NSPoint(x: bounds.width * 0.2, y: bounds.height * 0.4)
        let end = NSPoint(x: bounds.width * 0.8, y: bounds.height * 0.6)
        let root = try XCTUnwrap(preview.window.contentView)
        XCTAssertTrue(root.hitTest(root.convert(start, from: canvas)) === canvas,
                      "The image canvas must receive drags through its overlay")
        preview.window.sendEvent(mouse(.leftMouseDown, in: canvas, at: start))
        preview.window.sendEvent(mouse(.leftMouseDragged, in: canvas, at: end))
        preview.window.sendEvent(mouse(.leftMouseUp, in: canvas, at: end))
        let mark = try XCTUnwrap(preview.document.elements.first)
        XCTAssertEqual(mark.tool, .marker); XCTAssertTrue(mark.points.count >= 2)
        let document = preview.document
        XCTAssertTrue(preview.routeKey(key(53)))
        XCTAssertFalse(preview.isMarkupEditing)
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, document)
        preview.requestClose(); app.showPreview(record.id)
        XCTAssertEqual(app.preview?.document, document)
    }

    func testMouseDrawingToolsStoreNormalizedGeometryAndConstrainedShapes() throws {
        try withCanvas { canvas in
            var changes = 0; canvas.onChange = { changes += 1 }
            for tool in [ImageMarkupTool.pen, .marker, .rectangle, .ellipse, .arrow, .line] {
                canvas.load(.init()); canvas.setTool(tool)
                drag(canvas, from: NSPoint(x: 40, y: 48), to: NSPoint(x: 360, y: 192), through: NSPoint(x: 180, y: 120))
                let mark = try XCTUnwrap(canvas.document.elements.first)
                XCTAssertEqual(canvas.document.elements.count, 1); XCTAssertEqual(mark.tool, tool)
                XCTAssertEqual(mark.points.first, MarkupPoint(x: 0.1, y: 0.2))
                XCTAssertEqual(mark.points.last, MarkupPoint(x: 0.9, y: 0.8))
                XCTAssertEqual(mark.points.count, tool == .pen || tool == .marker ? 3 : 2)
                if tool == .marker { XCTAssertEqual(mark.color, .yellow); XCTAssertTrue(mark.lineWidth >= 0.02) }
                _ = try canvas.document.validated()
            }
            XCTAssertEqual(changes, 6)
            for tool in [ImageMarkupTool.ellipse, .rectangle] {
                canvas.load(.init()); canvas.setTool(tool)
                drag(canvas, from: NSPoint(x: 40, y: 48), to: NSPoint(x: 240, y: 168), flags: .shift)
                let mark = try XCTUnwrap(canvas.document.elements.first)
                let a = mark.points[0].position(in: canvas.bounds), b = mark.points[1].position(in: canvas.bounds)
                XCTAssertTrue(abs(abs(a.x - b.x) - abs(a.y - b.y)) < 0.001)
            }
            canvas.load(.init()); canvas.setTool(.pen)
            drag(canvas, from: NSPoint(x: -10, y: -20), to: NSPoint(x: 450, y: 300))
            XCTAssertEqual(canvas.document.elements.first?.points, [MarkupPoint(x: 0, y: 0), MarkupPoint(x: 1, y: 1)])
        }
    }

    func testSelectionMoveResizeStyleUndoRedoDeleteAndClear() throws {
        try withCanvas { canvas in
            canvas.setTool(.rectangle); canvas.filled = true
            drag(canvas, from: NSPoint(x: 80, y: 60), to: NSPoint(x: 240, y: 180))
            let original = canvas.document
            canvas.setTool(.select)
            drag(canvas, from: NSPoint(x: 160, y: 120), to: NSPoint(x: 200, y: 144))
            let moved = try XCTUnwrap(canvas.document.elements.first)
            XCTAssertTrue(abs(moved.points[0].x - 0.3) < 0.0001); XCTAssertTrue(abs(moved.points[0].y - 0.35) < 0.0001)
            XCTAssertEqual(canvas.selectedID, moved.id)
            let movedDocument = canvas.document
            let corner = moved.bounds(in: canvas.bounds).origin
            drag(canvas, from: corner, to: NSPoint(x: corner.x - 30, y: corner.y - 20))
            XCTAssertTrue(canvas.document.elements[0].points[0].x < moved.points[0].x)
            XCTAssertTrue(canvas.document.elements[0].points[0].y < moved.points[0].y)
            canvas.undoMarkup(); XCTAssertEqual(canvas.document, movedDocument)
            canvas.undoMarkup(); XCTAssertEqual(canvas.document, original)
            canvas.redoMarkup(); XCTAssertEqual(canvas.document, movedDocument)
            canvas.setTool(.select); click(canvas, at: NSPoint(x: 200, y: 144))
            canvas.applyStyle(color: .blue, width: 0.016, fill: false)
            XCTAssertEqual(canvas.document.elements[0].color, .blue); XCTAssertEqual(canvas.document.elements[0].lineWidth, 0.016)
            XCTAssertFalse(canvas.document.elements[0].fill)
            canvas.deleteSelected(); XCTAssertTrue(canvas.document.isEmpty)
            canvas.undoMarkup(); XCTAssertEqual(canvas.document.elements.count, 1)
            canvas.clearMarkup(); XCTAssertTrue(canvas.document.isEmpty)
            canvas.undoMarkup(); XCTAssertEqual(canvas.document.elements.count, 1)
            canvas.redoMarkup(); XCTAssertTrue(canvas.document.isEmpty)
            canvas.load(original); XCTAssertFalse(canvas.canUndo); XCTAssertFalse(canvas.canRedo); XCTAssertNil(canvas.selectedID)
        }
    }

    func testSelectingHollowShapeDoesNotStealInteriorClicksAndMoveClampsToImage() throws {
        try withCanvas { canvas in
            canvas.setTool(.ellipse); drag(canvas, from: NSPoint(x: 80, y: 48), to: NSPoint(x: 320, y: 192))
            canvas.setTool(.select); click(canvas, at: NSPoint(x: 200, y: 120))
            XCTAssertNil(canvas.selectedID)
            drag(canvas, from: NSPoint(x: 200, y: 192), to: NSPoint(x: 800, y: 700))
            let mark = try XCTUnwrap(canvas.document.elements.first)
            XCTAssertTrue(mark.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
            XCTAssertEqual(mark.points.last, MarkupPoint(x: 1, y: 1))
        }
    }

    func testTextEditingOwnsNativeTypingKeysAndFinishesUnicodeAndExistingText() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(f), keyboardBindings: KeyboardBindings(defaults: f.defaults)))
        defer { preview.onSaveMarkup = { _ in true }; preview.requestClose() }
        preview.beginMarkup(); preview.canvas.setTool(.text)
        click(preview.canvas, at: NSPoint(x: 40, y: 40))
        let editor = try XCTUnwrap(preview.canvas.textEditor)
        for (code, value) in [(UInt16(1), "s"), (35, "p"), (46, "m"), (49, " "), (51, ""), (123, ""), (124, ""), (125, ""), (126, "")] {
            XCTAssertFalse(preview.routeKey(key(code, text: value)), "The native text editor owns \(code)")
        }
        XCTAssertFalse(preview.routeKey(key(6, flags: .command, text: "z")))
        editor.string = "İstanbul 🌍 s p\nİkinci satır"; preview.canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertTrue(preview.routeKey(key(36, flags: .command)))
        XCTAssertFalse(preview.canvas.isTextEditing); XCTAssertTrue(preview.isMarkupEditing)
        let mark = try XCTUnwrap(preview.document.elements.first)
        XCTAssertEqual(mark.text, "İstanbul 🌍 s p\nİkinci satır")
        preview.canvas.setTool(.select)
        click(preview.canvas, at: mark.points[0].position(in: preview.canvas.bounds) + NSPoint(x: 8, y: 8), clicks: 2)
        let editing = try XCTUnwrap(preview.canvas.textEditor); editing.string = "Düzenlendi ✓"
        XCTAssertTrue(preview.routeKey(key(53)))
        XCTAssertEqual(preview.document.elements.count, 1); XCTAssertEqual(preview.document.elements[0].id, mark.id)
        XCTAssertEqual(preview.document.elements[0].text, "Düzenlendi ✓")
        preview.canvas.undoMarkup(); XCTAssertEqual(preview.document.elements[0].text, mark.text)
    }

    func testMarkupToolShortcutsRemapAndToolbarCallbacksStayInPreview() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let bindings = KeyboardBindings(defaults: f.defaults)
        let preview = try XCTUnwrap(ImagePreview(url: image(f), keyboardBindings: bindings))
        defer { preview.requestClose() }
        preview.beginMarkup()
        for (code, character, tool) in [(UInt16(9), "v", ImageMarkupTool.select), (11, "b", .pen), (4, "h", .marker), (15, "r", .rectangle), (31, "o", .ellipse), (0, "a", .arrow), (2, "d", .line), (17, "t", .text)] {
            XCTAssertTrue(preview.routeKey(key(code, text: character))); XCTAssertEqual(preview.canvas.tool, tool)
            XCTAssertEqual(preview.toolbar.toolButtons[tool]?.state, .on)
        }
        try bindings.set([KeyShortcut(keyCode: 38, modifiers: 0, keyLabel: "J")], for: .markupEllipse)
        preview.canvas.setTool(.pen)
        XCTAssertFalse(preview.routeKey(key(31, text: "o")))
        XCTAssertTrue(preview.routeKey(key(38, text: "j"))); XCTAssertEqual(preview.canvas.tool, .ellipse)
        preview.toolbar.onTool(.rectangle); preview.toolbar.onColor(.purple); preview.toolbar.onWidth(0.016); preview.toolbar.onFill(true)
        XCTAssertEqual(preview.canvas.tool, .rectangle); XCTAssertEqual(preview.canvas.color, .purple)
        XCTAssertEqual(preview.canvas.lineWidth, 0.016); XCTAssertTrue(preview.canvas.filled)
    }

    func testSpaceHoldPanAndKeyUpKeepMarkupDocumentAndWindowOpen() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(f), keyboardBindings: KeyboardBindings(defaults: f.defaults)))
        preview.onSaveMarkup = { _ in true }; defer { preview.requestClose() }
        stroke(preview); let before = preview.document, frame = preview.window.frame
        let scroll = preview.scroll, canvas = preview.canvas
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertTrue(scroll.canPan); XCTAssertFalse(canvas.mouseDownCanMoveWindow)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(preview.routeKey(key(49, text: " "))); XCTAssertTrue(canvas.spaceHeld)
        drag(canvas, from: NSPoint(x: 80, y: 80), to: NSPoint(x: -20, y: -20))
        XCTAssertTrue(scroll.contentView.bounds.minX > 0); XCTAssertTrue(scroll.contentView.bounds.minY > 0)
        XCTAssertEqual(preview.document, before); XCTAssertEqual(preview.window.frame, frame)
        let panel = try XCTUnwrap(preview.window as? ActionPreviewPanel)
        XCTAssertTrue(panel.onKeyUp?(key(49, text: " ", type: .keyUp)) ?? false)
        XCTAssertFalse(canvas.spaceHeld); XCTAssertTrue(preview.isMarkupEditing)
        XCTAssertEqual(preview.document, before)
        preview.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); XCTAssertFalse(canvas.spaceHeld)
    }

    func testCopyFlushesActualStoreMarkupAndPreviewRemainsEditable() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); var copies = [URL]()
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { copies.append($0) }, copyText: { _ in }, library: store)
        let board = NSPasteboard(name: .init("markup-copy-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        app.showPreview(record.id); let preview = try XCTUnwrap(app.preview)
        defer { preview.requestClose() }
        stroke(preview); let document = preview.document
        XCTAssertTrue(preview.hasUnsavedMarkup); XCTAssertNil(try store.item(record.id)?.imageMarkup)
        XCTAssertTrue(preview.routeKey(key(36)))
        let saved = try XCTUnwrap(store.item(record.id)), url = try XCTUnwrap(saved.fileURL)
        XCTAssertEqual(saved.imageMarkup, document); XCTAssertEqual(copies, [url])
        XCTAssertFalse(preview.hasUnsavedMarkup); XCTAssertTrue(preview.isMarkupEditing)
        XCTAssertEqual(preview.document, document); XCTAssertTrue(preview.canvas.canUndo)
        preview.canvas.undoMarkup(); XCTAssertTrue(preview.document.isEmpty)
        XCTAssertTrue(preview.routeKey(key(1, flags: .command, text: "s")))
        XCTAssertNil(try store.item(record.id)?.imageMarkup)
    }

    func testFailedSaveBlocksCopyNavigationAndCloseUntilRetrySucceeds() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        _ = try store.captureImage(image(f)); f.date += 1
        let record = try store.captureImage(image(f)); _ = try store.captureText("Another shelf")
        var copies = 0
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in copies += 1 }, copyText: { _ in }, library: store)
        line.setPresentation(.all, requestFocus: false)
        let board = NSPasteboard(name: .init("markup-failed-save-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        app.showPreview(record.id); let preview = try XCTUnwrap(app.preview), panel = preview.window
        let realSave = preview.onSaveMarkup; defer { preview.onSaveMarkup = realSave; preview.requestClose() }
        stroke(preview); let draft = preview.document
        preview.onSaveMarkup = { _ in false }
        XCTAssertTrue(preview.routeKey(key(36))); XCTAssertEqual(copies, 0)
        XCTAssertTrue(preview.routeKey(key(124))); XCTAssertEqual(app.previewSession?.currentID, record.id)
        XCTAssertTrue(preview.routeKey(key(125))); XCTAssertTrue(app.preview === preview)
        preview.controls.onMove(1); XCTAssertEqual(app.previewSession?.currentID, record.id)
        preview.controls.onClose(); XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(preview.windowShouldClose(panel)); XCTAssertTrue(preview.hasUnsavedMarkup)
        XCTAssertEqual(preview.document, draft); XCTAssertTrue(preview.isMarkupEditing)
        XCTAssertEqual(preview.toolbar.statusLabel.stringValue, L("Image changes could not be saved. Your edits are still here."))
        preview.onSaveMarkup = realSave; XCTAssertTrue(preview.flushEdits())
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, draft)
        preview.requestClose(); XCTAssertFalse(panel.isVisible)
    }

    func testCrossShelfPanelNavigationFlushesAndRestoresSavedMarkup() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); _ = try store.captureText("Text destination")
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in }, copyText: { _ in }, library: store)
        line.setPresentation(.both, requestFocus: false)
        let board = NSPasteboard(name: .init("markup-cross-shelf-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        app.showPreview(record.id); let preview = try XCTUnwrap(app.preview), panel = try XCTUnwrap(preview.window as? ActionPreviewPanel)
        defer { panel.close() }
        stroke(preview, tool: .arrow); let document = preview.document, number = panel.windowNumber
        XCTAssertTrue(panel.onKey?(key(125)) ?? false)
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, document)
        XCTAssertTrue(app.textPreview?.window === panel); XCTAssertEqual(panel.windowNumber, number); XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.onKey?(key(126)) ?? false)
        let reopened = try XCTUnwrap(app.preview)
        XCTAssertTrue(reopened.window === panel); XCTAssertEqual(reopened.document, document)
        XCTAssertFalse(reopened.hasUnsavedMarkup); XCTAssertFalse(reopened.isMarkupEditing)
        reopened.beginMarkup(); reopened.canvas.setTool(.select)
        XCTAssertEqual(reopened.document.elements.first?.tool, .arrow)
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, document)
    }

    func testClosingPreviewCommitsPendingNativeTextAndReopeningKeepsEditableVectors() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f))
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in }, copyText: { _ in }, library: store)
        let board = NSPasteboard(name: .init("markup-close-text-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        app.showPreview(record.id); let preview = try XCTUnwrap(app.preview)
        preview.beginMarkup(); preview.canvas.setTool(.text); click(preview.canvas, at: NSPoint(x: 50, y: 50))
        try XCTUnwrap(preview.canvas.textEditor).string = "Kapanırken kaydet ✓"
        preview.controls.onClose(); XCTAssertNil(app.preview); XCTAssertNil(app.previewSession)
        let saved = try XCTUnwrap(store.item(record.id)); XCTAssertEqual(saved.imageMarkup?.elements.first?.text, "Kapanırken kaydet ✓")
        app.showPreview(record.id); let reopened = try XCTUnwrap(app.preview); defer { reopened.requestClose() }
        XCTAssertEqual(reopened.document, saved.imageMarkup)
        reopened.beginMarkup(); reopened.canvas.clearMarkup(); XCTAssertTrue(reopened.finishMarkup())
        XCTAssertNil(try store.item(record.id)?.imageMarkup)
    }

    func testLibraryPreviewUsesSameMarkupPersistenceCopyAndReopenFlow() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); try store.retain([record.id])
        let board = NSPasteboard(name: .init("markup-library-\(UUID())")); defer { board.releaseGlobally() }
        let model = LibraryModel(store: store, copyPasteboard: board)
        wait { model.ids == [record.id] && !model.loading }
        let controller = LibraryPreviewController(model: model); defer { controller.close() }
        controller.show(record.id); let preview = try XCTUnwrap(controller.image)
        stroke(preview, tool: .rectangle); let document = preview.document
        let changeCount = board.changeCount
        preview.controls.onCopy()
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, document)
        XCTAssertTrue(model.copiedIDs.contains(record.id)); XCTAssertTrue(board.changeCount > changeCount)
        XCTAssertTrue(board.types?.contains(.png) == true)
        controller.close(); XCTAssertNil(controller.currentID)
        controller.show(record.id)
        let reopened = try XCTUnwrap(controller.image)
        XCTAssertEqual(reopened.document, document); XCTAssertFalse(reopened.hasUnsavedMarkup)
        reopened.beginMarkup(); XCTAssertTrue(reopened.isMarkupEditing)
    }

    func testMainLibraryCopyDragAndTrashFlushDirtyPreviewBeforeUsingImage() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); try store.retain([record.id])
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        let board = NSPasteboard(name: .init("markup-main-library-\(UUID())")); defer { board.releaseGlobally() }
        let library = LibraryWindowController(store: store, line: line, copyPasteboard: board)
        defer { library.dismissPreviews(); library.window?.close() }
        wait { library.model.ids == [record.id] && !library.model.loading }
        XCTAssertTrue(library.model.select(record.id)); library.model.onPreview?(record.id)
        let canvas = try libraryStroke(library), first = canvas.document
        XCTAssertNil(try store.item(record.id)?.imageMarkup)
        let beforeCopy = board.changeCount
        library.model.copy()
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, first)
        XCTAssertTrue(board.changeCount > beforeCopy); XCTAssertTrue(board.types?.contains(.png) == true)
        XCTAssertTrue(library.previewWindow?.isVisible == true); XCTAssertTrue(canvas.canUndo)

        canvas.clearMarkup(); _ = try libraryStroke(library, tool: .arrow); let second = canvas.document
        let dragged = library.model.dragItems(record.id)
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, second)
        XCTAssertEqual(dragged.first?.sourceURL, try store.item(record.id)?.fileURL)

        canvas.clearMarkup(); _ = try libraryStroke(library, tool: .rectangle); let final = canvas.document
        library.model.trash()
        let trashed = try XCTUnwrap(store.item(record.id))
        XCTAssertEqual(trashed.imageMarkup, final); XCTAssertTrue(trashed.deletedAt != nil)
        wait { library.previewCurrentID == nil && library.model.ids.isEmpty && !library.model.loading }
        XCTAssertTrue(library.previewWindow?.isVisible == true)
        XCTAssertTrue(store.canUndoTrash)
        library.model.undoTrash()
        wait { library.previewCurrentID == record.id && library.model.ids == [record.id] && !library.model.loading }
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, final)
        XCTAssertNil(try store.item(record.id)?.deletedAt)
    }

    func testFailedMainLibraryFlushBlocksCopyDragAndTrashWithoutLosingDraft() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); try store.retain([record.id])
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        let board = NSPasteboard(name: .init("markup-main-failed-flush-\(UUID())")); defer { board.releaseGlobally() }
        let library = LibraryWindowController(store: store, line: line, copyPasteboard: board)
        let realFlush = library.model.onFlushPreview
        defer { library.model.onFlushPreview = realFlush; library.dismissPreviews(); library.window?.close() }
        wait { library.model.ids == [record.id] && !library.model.loading }
        XCTAssertTrue(library.model.select(record.id)); library.model.onPreview?(record.id)
        let canvas = try libraryStroke(library), draft = canvas.document, count = board.changeCount
        library.model.onFlushPreview = { false }
        library.model.copy(); XCTAssertEqual(board.changeCount, count)
        XCTAssertTrue(library.model.dragItems(record.id).isEmpty)
        library.model.trash(); XCTAssertNil(try store.item(record.id)?.deletedAt)
        XCTAssertNil(try store.item(record.id)?.imageMarkup)
        XCTAssertEqual(canvas.document, draft); XCTAssertTrue(library.previewWindow?.isVisible == true)
        library.model.onFlushPreview = realFlush; library.model.copy()
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, draft); XCTAssertTrue(board.changeCount > count)
    }

    func testOpeningShelfAfterLibraryFlushesAndClosesOldPreviewForSameItem() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let record = try store.captureImage(image(f)); try store.retain([record.id])
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        let board = NSPasteboard(name: .init("markup-library-to-shelf-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: board)
        app.showLibrary(); let library = try XCTUnwrap(app.libraryController)
        defer { app.preview?.requestClose(); library.dismissPreviews(); library.window?.close() }
        wait { library.model.ids == [record.id] && !library.model.loading }
        library.model.onPreview?(record.id)
        let oldWindow = try XCTUnwrap(library.previewWindow), canvas = try libraryStroke(library), draft = canvas.document
        XCTAssertNil(try store.item(record.id)?.imageMarkup)
        app.showPreview(record.id)
        XCTAssertEqual(try store.item(record.id)?.imageMarkup, draft)
        XCTAssertFalse(oldWindow.isVisible); XCTAssertNil(library.previewWindow)
        let shelfPreview = try XCTUnwrap(app.preview)
        XCTAssertEqual(shelfPreview.document, draft); XCTAssertFalse(shelfPreview.hasUnsavedMarkup)
        XCTAssertEqual(app.previewSession?.currentID, record.id)
    }
}

private func + (lhs: NSPoint, rhs: NSPoint) -> NSPoint { NSPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
