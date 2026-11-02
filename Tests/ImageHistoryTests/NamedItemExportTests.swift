import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class NamedItemExportTests: HistoryTestCase {
    func testExportUsesTheNameGivenInTheLibrary() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        let image = try store.nameAndPin(try store.captureImage(try f.image(owned: false)).id, name: "Invoice March")
        let text = try store.nameAndPin(try XCTUnwrap(store.captureText("Agenda\n1. Budget")).id, name: "Meeting/notes: v2")
        let link = try store.nameAndPin(try store.captureLink(URL(string: "https://example.com/releases")!).id, name: "Release notes")
        let unnamed = try XCTUnwrap(store.captureText("Plain note"))
        let sources = try LibraryTransfer.exportSources([image, text, link, unnamed], store: store)
        XCTAssertEqual(Array(sources.map(\.name).prefix(3)), ["Invoice March.png", "Meeting-notes- v2.txt", "Release notes.webloc"])
        XCTAssertEqual(sources[3].name, "Text \(unnamed.id).txt")
    }
    func testNamedImageOnTheShelfExportsUnderItsName() {
        let url = URL(fileURLWithPath: "/tmp/Clipboard 1.png")
        XCTAssertEqual(Pegged(url: url, thumb: nil, originalPath: "/tmp/Screenshot A.png", title: "Invoice March").exportName, "Invoice March.png")
        XCTAssertEqual(Pegged(url: url, thumb: nil, originalPath: "/tmp/Screenshot A.png").exportName, "Screenshot A.png")
    }
    func testNamedTextOnTheShelfExportsUnderItsName() {
        let id = UUID(), url = URL(fileURLWithPath: "/tmp/Text \(id).txt")
        XCTAssertEqual(HistoryFiles.exportName(for: url, originalPath: nil, title: "  Meeting notes "), "Meeting notes.txt")
        XCTAssertEqual(HistoryFiles.exportName(for: url, originalPath: nil, title: nil), "Text \(id).txt")
        XCTAssertEqual(HistoryFiles.exportName(for: url, originalPath: nil, title: "   "), "Text \(id).txt")
    }
}
