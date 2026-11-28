import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// "Copy new screenshots to the clipboard": a capture from the screenshot
/// folder or a watched folder also lands on the clipboard when the setting is
/// on. Clipboard arrivals and recordings never copy themselves, and a capture
/// keeps off the clipboard while a direct paste may still read it.
@MainActor private final class CaptureCopyClipboard: ClipboardSource {
    var count = 52000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? { values[index][type] }
    func copy(_ values: [[NSPasteboard.PasteboardType: Data]]) { count += 1; self.values = values }
}

@MainActor final class CaptureCopyTests: HistoryTestCase {
    private func recording(_ f: SyntheticFixture) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("windows/tests/fixtures/recordings/synthetic-rgb-tone.mov")
        try FileManager.default.createDirectory(at: f.inbox, withIntermediateDirectories: true)
        let target = f.inbox.appendingPathComponent("Screen Recording \(UUID()).mov")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    func testNewCaptureCopiesOnlyWhenEnabled() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        var copied: [URL] = []
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
            moveToTrash: fixtureTrash(f.folder), copyImage: { copied.append($0) }, copyText: { _ in }, library: store)

        XCTAssertFalse(line.copiesNewCaptures, "The setting is off out of the box")
        XCTAssertNotNil(line.hangCapture(try f.image()))
        XCTAssertTrue(copied.isEmpty, "A capture must not touch the clipboard while the setting is off")

        line.copiesNewCaptures = true
        let id = try XCTUnwrap(line.hangCapture(try f.image()))
        let hung = try XCTUnwrap(line.items.first { $0.id == id })
        XCTAssertEqual(copied, [hung.url], "The new capture is copied once, as the card would be")
        XCTAssertEqual(line.items.count, 2)

        XCTAssertNotNil(line.hang(try f.image()))
        XCTAssertEqual(copied.count, 1, "An image that came from the clipboard is not copied back")

        XCTAssertNotNil(line.hangCapture(try recording(f)))
        XCTAssertEqual(copied.count, 1, "A screen recording hangs without replacing the clipboard")
    }

    func testImageCopiedFromAnotherAppIsNotCopiedBackButAScreenshotIs() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        _ = NSApplication.shared
        let oldOwn = ClipboardWatcher.ownChangeCount; defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        var copied: [URL] = []
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
            moveToTrash: fixtureTrash(f.folder), copyImage: { copied.append($0) }, copyText: { _ in })
        line.setPresentation(.textsLinks, requestFocus: false)
        line.copiesNewCaptures = true
        let clipboard = CaptureCopyClipboard()
        let app = AppDelegate(line: line, clipboardSource: clipboard, watchesFiles: false)
        defer { app.stopClipboardImagesForTesting() }
        app.pollClipboardImagesForTesting()
        clipboard.copy([[.png: try Data(contentsOf: try f.image(owned: false))]])
        app.pollClipboardImagesForTesting()
        XCTAssertEqual(line.items.count, 1, "The copied image hangs through the real clipboard watcher")
        XCTAssertTrue(copied.isEmpty, "A copied image must not be written back over the original clipboard")

        app.receiveCaptureForTesting(try f.image())
        XCTAssertEqual(line.items.count, 2)
        XCTAssertEqual(copied.count, 1, "A screenshot through the same app path is copied")
    }

    func testCaptureDuringDirectPasteKeepsOffTheClipboard() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        _ = NSApplication.shared
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        var copied: [URL] = []
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
            copyImage: { copied.append($0) }, copyText: { _ in }, library: store)
        line.setPresentation(.textsLinks, requestFocus: false)
        line.copiesNewCaptures = true
        let link = try XCTUnwrap(line.links.add(URL(string: "https://example.com/paste")!))
        let field = NSObject(); var frontmost: pid_t? = 101
        var app: AppDelegate!
        var duringPaste: URL?
        let environment = DirectPasteCoordinator.Environment(ownPID: ProcessInfo.processInfo.processIdentifier, trusted: { true }, frontmostPID: { frontmost }, running: { $0 == 101 },
            focusedField: { $0 == 101 ? .init(identity: field, editable: true, secure: false) : nil }, sameField: { $0.identity === $1.identity },
            activate: { frontmost = $0; return true },
            write: { _ in if let url = duringPaste { duringPaste = nil; app.receiveCaptureForTesting(url) }; return true },
            sendPaste: { _ in true }, pause: { await Task.yield() }, inputReleased: { true }, ownsKeyboardFocus: { false })
        app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: NSPasteboard(name: .init("capture-paste-\(UUID())")), directPaste: DirectPasteCoordinator(environment: environment), ownsKeyboardFocus: { false })
        duringPaste = try f.image()
        line.focusShelf(.links, requestFocus: false); line.links.select(link.id, width: 1000)
        app.showCommands(origin: .line)
        let palette = try XCTUnwrap(app.commandPalette)
        let index = try XCTUnwrap(palette.visibleCommands.firstIndex { $0.id == KeyboardAction.paste.rawValue })
        palette.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        palette.executeSelected()
        let end = Date().addingTimeInterval(5)
        while line.notice != L("Pasted") && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(line.notice, L("Pasted"))
        XCTAssertNil(duringPaste, "The capture arrived while the paste wrote the clipboard")
        XCTAssertEqual(line.items.count, 1, "The capture still hangs")
        XCTAssertTrue(copied.isEmpty, "A capture during a direct paste must not replace what is being pasted")

        app.receiveCaptureForTesting(try f.image())
        XCTAssertEqual(line.items.count, 2)
        XCTAssertTrue(copied.isEmpty, "The target app may still be reading the clipboard right after the paste")
    }

    func testCaptureThatCannotBeCopiedSaysSo() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        var copied: [URL] = []
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
            moveToTrash: fixtureTrash(f.folder), copyImage: { copied.append($0) }, copyText: { _ in })
        line.copiesNewCaptures = true
        line.onFlushPreview = { false } // an open edit that cannot be saved
        var reported = 0
        line.onCaptureNotCopied = { reported += 1 }
        XCTAssertNotNil(line.hangCapture(try f.image()), "The capture still hangs")
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(line.notice, L("The new screenshot was not copied"))
        XCTAssertEqual(reported, 1, "The app is told so it can bring the notice into view")
        line.onFlushPreview = { true }
        XCTAssertNotNil(line.hangCapture(try f.image()))
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(reported, 1, "A successful copy does not report a failure")
    }

    func testSettingSurvivesRestart() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        line.copiesNewCaptures = true
        XCTAssertTrue(f.line().copiesNewCaptures)
        line.copiesNewCaptures = false
        XCTAssertFalse(f.line().copiesNewCaptures)
    }
}
