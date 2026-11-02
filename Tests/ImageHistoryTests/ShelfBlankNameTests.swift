import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShelfBlankNameTests: HistoryTestCase {
    func testShelvesTrimTheLibraryNameAndIgnoreABlankOne() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        let text = try XCTUnwrap(store.captureText("Quarterly plan\nsecond line")), image = try store.captureImage(try f.image(owned: false))
        try store.retain([text.id, image.id])
        try store.update(text.id) { $0.title = "   " }
        try store.update(image.id) { $0.title = "  Invoice  " }
        let texts = TextHistory(defaults: f.defaults, folder: f.inbox.appendingPathComponent("Texts"), library: store)
        let images = ImageHistory(defaults: f.defaults, inbox: f.inbox, library: store)
        XCTAssertNil(try XCTUnwrap(texts.entries.first { $0.id == text.id }).title)
        XCTAssertEqual(try XCTUnwrap(images.entries.first { $0.id == image.id }).title, "Invoice")
    }
}
