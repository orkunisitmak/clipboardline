import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class CopyLargeImageTests: HistoryTestCase {
    func testStoredImageOverTheCaptureLimitIsStillCopied() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let large = f.folder.appendingPathComponent("Large.png")
        try Data(count: ClipboardWatcher.maximumDataBytes + 1024).write(to: large)
        let board = NSPasteboard(name: .init("copy-large-\(UUID())")); defer { board.releaseGlobally() }
        let payload = try ClipboardTransfer.imageItems([large])
        XCTAssertTrue(ClipboardTransfer.write(payload, to: board))
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .png)?.count, ClipboardWatcher.maximumDataBytes + 1024)
    }
}
