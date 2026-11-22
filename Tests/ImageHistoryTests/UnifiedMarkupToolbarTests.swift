import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class UnifiedMarkupToolbarTests: HistoryTestCase {
    private func image(_ fixture: SyntheticFixture) throws -> URL {
        let url = try fixture.image()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = bitmap.bitmapData { memset(bytes, 255, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func resize(_ preview: ImagePreview, to size: NSSize) throws -> NSView {
        preview.window.setContentSize(size)
        let surface = try XCTUnwrap(preview.window.contentView)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, in: $0) }
    }

    private func button(_ label: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(NSButton.self, in: root).first { $0.accessibilityLabel() == label })
    }

    private func send(_ control: NSControl) throws {
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
    }

    private func key(_ code: UInt16, text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }

    private func draw(_ preview: ImagePreview) {
        let canvas = preview.canvas
        let start = NSPoint(x: canvas.bounds.width * 0.2, y: canvas.bounds.height * 0.25)
        let end = NSPoint(x: canvas.bounds.width * 0.7, y: canvas.bounds.height * 0.75)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: preview.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, start))
        canvas.mouseDragged(with: event(.leftMouseDragged, end))
        canvas.mouseUp(with: event(.leftMouseUp, end))
    }

    private func selectFirstMark(_ preview: ImagePreview) throws {
        let canvas = preview.canvas
        let point = try XCTUnwrap(canvas.document.elements.first?.points.first).position(in: canvas.bounds)
        canvas.setTool(.select)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: preview.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
        XCTAssertTrue(canvas.selectedID != nil)
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        view === ancestor || view.isDescendant(of: ancestor)
    }

    /// Markup makes the canvas (an NSControl) first responder. Mouse events routed
    /// through the panel must still reach it instead of being read as key events.
    func testPanelRoutesMouseEventsToMarkupCanvas() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(fixture)))
        defer { preview.requestClose() }
        let panel = try XCTUnwrap(preview.window as? ActionPreviewPanel)
        preview.beginMarkup(); preview.canvas.setTool(.rectangle)
        XCTAssertTrue(panel.firstResponder === preview.canvas)
        let canvas = preview.canvas
        let start = NSPoint(x: canvas.bounds.width * 0.2, y: canvas.bounds.height * 0.25)
        let end = NSPoint(x: canvas.bounds.width * 0.7, y: canvas.bounds.height * 0.75)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Before the fix, reading keyCode from this mouse event raised
        // NSInternalInconsistencyException inside sendEvent and the click was lost.
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            panel.sendEvent(event(type, point))
        }
        XCTAssertTrue(preview.isMarkupEditing)
    }

    func testMarkupSharesTopRowAndFreesBottomCanvas() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(fixture)))
        defer { preview.requestClose() }
        preview.beginMarkup()
        let surface = try resize(preview, to: NSSize(width: 1100, height: 700))
        let row = preview.controls.convert(preview.controls.bounds, to: surface)
        let tools = preview.toolbar.convert(preview.toolbar.bounds, to: surface)
        let pin = preview.controls.pinButton.convert(preview.controls.pinButton.bounds, to: surface)
        XCTAssertTrue(preview.controls.leadingAccessory === preview.toolbar)
        XCTAssertTrue(isDescendant(preview.toolbar, of: preview.controls))
        XCTAssertTrue(tools.maxX < pin.minX, "Drawing tools belong to the left of preview actions")
        XCTAssertTrue(abs(tools.midY - pin.midY) < 2)
        XCTAssertTrue(row.maxY > surface.bounds.maxY - 16)
        XCTAssertTrue(row.height <= 48, "Markup stays in a single compact HUD row")
        XCTAssertTrue(preview.scroll.frame.maxY <= row.minY - 4)
        XCTAssertTrue(preview.scroll.frame.minY < 30, "There is no reserved bottom toolbar strip")
        XCTAssertTrue(preview.scroll.frame.height > surface.bounds.height - 130, "The former 90-point bottom bar returns space to the canvas")
        let sharedHUDs = descendants(NSVisualEffectView.self, in: surface).filter { isDescendant(preview.toolbar, of: $0) }
        XCTAssertEqual(sharedHUDs.count, 1)
        let pen = try XCTUnwrap(preview.toolbar.toolButtons[.pen])
        let point = pen.convert(NSPoint(x: pen.bounds.midX, y: pen.bounds.midY), to: surface)
        XCTAssertTrue(surface.hitTest(point).map { isDescendant($0, of: pen) } == true)
    }

    func testNarrowToolbarKeepsEveryToolAndNavigationReachableInOneRow() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(fixture)))
        defer { preview.requestClose() }
        preview.beginMarkup()
        let surface = try resize(preview, to: NSSize(width: 640, height: 480))
        let row = preview.controls.convert(preview.controls.bounds, to: surface)
        XCTAssertTrue(preview.toolbar.isCompact)
        XCTAssertFalse(preview.toolbar.toolPicker.isHidden)
        XCTAssertTrue(row.minX >= 0 && row.maxX <= surface.bounds.maxX)
        XCTAssertTrue(row.height <= 48)
        XCTAssertTrue(preview.scroll.frame.maxY < row.minY)
        for control in [preview.toolbar.toolPicker, preview.toolbar.styleButton,
                        preview.toolbar.moreButton, preview.controls.pinButton] as [NSControl] {
            let frame = control.convert(control.bounds, to: surface)
            XCTAssertTrue(frame.width > 0 && frame.height > 0)
            XCTAssertTrue(frame.minX >= row.minX && frame.maxX <= row.maxX)
            XCTAssertTrue(abs(frame.midY - row.midY) < 2)
            let hit = surface.hitTest(NSPoint(x: frame.midX, y: frame.midY))
            XCTAssertTrue(hit.map { isDescendant($0, of: control) } == true)
        }
        for tool in ImageMarkupTool.allCases {
            let tag = try XCTUnwrap(preview.toolbar.toolButtons[tool]).tag
            XCTAssertTrue(preview.toolbar.toolPicker.selectItem(withTag: tag))
            try send(preview.toolbar.toolPicker)
            XCTAssertEqual(preview.canvas.tool, tool)
        }
        var moves: [Int] = [], copied = 0, pinned = 0
        preview.controls.onMove = { moves.append($0) }
        preview.controls.onCopy = { copied += 1 }; preview.controls.onPin = { pinned += 1 }
        try send(button(L("Previous item"), in: preview.controls))
        try send(button(L("Next item"), in: preview.controls))
        try send(button(L("Copy"), in: preview.controls)); try send(preview.controls.pinButton)
        XCTAssertEqual(moves, [-1, 1]); XCTAssertEqual(copied, 1); XCTAssertEqual(pinned, 1)
    }

    func testStylePopoverKeepsNativeKeyOwnershipAndAppliesDrawingStyles() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(fixture)))
        preview.onSaveMarkup = { _ in true }; defer { preview.onSaveMarkup = { _ in true }; preview.requestClose() }
        preview.show(); preview.beginMarkup()
        _ = try resize(preview, to: NSSize(width: 640, height: 480))
        try send(preview.toolbar.styleButton)
        XCTAssertTrue(preview.toolbar.stylePopover.isShown)
        let originalTool = preview.canvas.tool
        XCTAssertFalse(preview.routeKey(key(53)))
        XCTAssertFalse(preview.routeKey(key(49, text: " ")))
        XCTAssertFalse(preview.routeKey(key(4, text: "h")))
        XCTAssertEqual(preview.canvas.tool, originalTool); XCTAssertFalse(preview.canvas.spaceHeld)
        XCTAssertTrue(preview.isMarkupEditing)
        preview.toolbar.stylePopover.close()
        preview.canvas.setTool(.marker)
        preview.toolbar.widthPicker.selectItem(at: 3); try send(preview.toolbar.widthPicker)
        XCTAssertEqual(preview.canvas.lineWidth, 0.09)
        preview.toolbar.colorWell.color = MarkupColor.blue.nsColor; try send(preview.toolbar.colorWell)
        XCTAssertEqual(preview.canvas.color, .blue)
        preview.canvas.setTool(.rectangle)
        preview.toolbar.fillButton.state = .on; try send(preview.toolbar.fillButton)
        draw(preview)
        XCTAssertEqual(preview.document.elements.first?.tool, .rectangle)
        XCTAssertTrue(preview.document.elements.first?.fill == true)
        preview.canvas.setTool(.text)
        preview.toolbar.fontPicker.selectItem(at: 2); try send(preview.toolbar.fontPicker)
        XCTAssertEqual(preview.canvas.fontSize, 0.08)
        XCTAssertTrue(preview.finishMarkup())
    }

    func testOverflowActionsAndFailedDoneKeepDraftAndAllowRetry() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let preview = try XCTUnwrap(ImagePreview(url: image(fixture)))
        preview.onSaveMarkup = { _ in true }; defer { preview.onSaveMarkup = { _ in true }; preview.requestClose() }
        preview.show(); preview.beginMarkup()
        _ = try resize(preview, to: NSSize(width: 640, height: 480))
        preview.canvas.setTool(.rectangle); draw(preview)
        let draft = preview.document
        try send(preview.toolbar.moreButton)
        let overflow = try XCTUnwrap(preview.toolbar.morePopover.contentViewController?.view)
        try send(button(L("Undo"), in: overflow)); XCTAssertTrue(preview.document.isEmpty)
        try send(button(L("Redo"), in: overflow)); XCTAssertEqual(preview.document, draft)
        try selectFirstMark(preview)
        try send(button(L("Delete annotation"), in: overflow)); XCTAssertTrue(preview.document.isEmpty)
        try send(button(L("Undo"), in: overflow)); XCTAssertEqual(preview.document, draft)
        try send(button(L("Clear annotations"), in: overflow)); XCTAssertTrue(preview.document.isEmpty)
        try send(button(L("Undo"), in: overflow)); XCTAssertEqual(preview.document, draft)
        preview.toolbar.morePopover.close()
        preview.onSaveMarkup = { _ in false }
        try send(button(L("Done"), in: preview.toolbar))
        XCTAssertTrue(preview.isMarkupEditing); XCTAssertEqual(preview.document, draft)
        XCTAssertTrue(preview.controls.leadingAccessory === preview.toolbar)
        XCTAssertEqual(preview.toolbar.statusLabel.stringValue, L("Image changes could not be saved. Your edits are still here."))
        preview.onSaveMarkup = { _ in true }
        try send(button(L("Done"), in: preview.toolbar))
        XCTAssertFalse(preview.isMarkupEditing); XCTAssertFalse(preview.hasUnsavedMarkup)
        XCTAssertNil(preview.controls.leadingAccessory)
    }

    func testFinishingAndReusingPanelRemoveMarkupAccessoryAndClosePopovers() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let url = try image(fixture), preview = try XCTUnwrap(ImagePreview(url: url))
        preview.show()
        let browsingSize = preview.window.frame.size
        preview.beginMarkup(); try send(preview.toolbar.styleButton)
        XCTAssertTrue(preview.toolbar.stylePopover.isShown)
        XCTAssertTrue(preview.finishMarkup())
        XCTAssertFalse(preview.toolbar.stylePopover.isShown); XCTAssertFalse(preview.toolbar.morePopover.isShown)
        XCTAssertNil(preview.controls.leadingAccessory)
        XCTAssertEqual(preview.window.frame.size, browsingSize)
        XCTAssertEqual(preview.scroll.frame, try XCTUnwrap(preview.window.contentView).bounds)
        preview.beginMarkup(); try send(preview.toolbar.moreButton)
        XCTAssertTrue(preview.toolbar.morePopover.isShown)
        let panel = try XCTUnwrap(preview.window as? ActionPreviewPanel)
        let text = TextPreview(text: "Another kind", window: panel)
        XCTAssertTrue(text.window === panel)
        XCTAssertFalse(preview.toolbar.stylePopover.isShown); XCTAssertFalse(preview.toolbar.morePopover.isShown)
        XCTAssertNil(text.controls.leadingAccessory)
        XCTAssertFalse(descendants(ImageMarkupToolbar.self, in: try XCTUnwrap(panel.contentView)).contains { $0 === preview.toolbar })
        let returned = try XCTUnwrap(ImagePreview(url: url, window: panel))
        defer { returned.requestClose() }
        XCTAssertNil(returned.controls.leadingAccessory); XCTAssertFalse(returned.isMarkupEditing)
        returned.beginMarkup()
        XCTAssertTrue(returned.controls.leadingAccessory === returned.toolbar)
    }
}
