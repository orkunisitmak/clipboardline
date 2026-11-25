import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class PasteMarksCopiedTests: HistoryTestCase {
    func testPastingAnOlderLinkMovesItToTheFrontLikeCopy() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        _ = NSApplication.shared
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in }, copyText: { _ in }, library: store)
        line.setPresentation(.all, requestFocus: false)
        let older = try XCTUnwrap(line.links.add(URL(string: "https://example.com/older")!)); f.date.addTimeInterval(60)
        _ = line.links.add(URL(string: "https://example.com/newer")!); f.date.addTimeInterval(60)
        let field = NSObject(); var frontmost: pid_t? = 101
        let environment = DirectPasteCoordinator.Environment(ownPID: ProcessInfo.processInfo.processIdentifier, trusted: { true }, frontmostPID: { frontmost }, running: { $0 == 101 },
            focusedField: { $0 == 101 ? .init(identity: field, editable: true, secure: false) : nil }, sameField: { $0.identity === $1.identity },
            activate: { frontmost = $0; return true }, write: { _ in true }, sendPaste: { _ in true }, pause: { await Task.yield() }, inputReleased: { true }, ownsKeyboardFocus: { false })
        let app = AppDelegate(line: line, watchesFiles: false, copyPasteboard: NSPasteboard(name: .init("paste-copied-\(UUID())")), directPaste: DirectPasteCoordinator(environment: environment), ownsKeyboardFocus: { false })
        line.focusShelf(.links, requestFocus: false); line.links.select(older.id, width: 1000)
        app.showCommands(origin: .line)
        let palette = try XCTUnwrap(app.commandPalette)
        let index = try XCTUnwrap(palette.visibleCommands.firstIndex { $0.id == KeyboardAction.paste.rawValue })
        palette.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        palette.executeSelected()
        let end = Date().addingTimeInterval(5)
        while line.notice != L("Pasted") && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(line.notice, L("Pasted"))
        XCTAssertNotNil(try store.item(older.id)?.lastCopiedAt)
        XCTAssertEqual(try store.shelfItems(.link).first?.originalURL, "https://example.com/older")
    }
}
