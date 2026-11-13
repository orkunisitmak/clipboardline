import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// "Copy new screenshots to the clipboard": a capture from the screenshot
/// folder or a watched folder also lands on the clipboard when the setting is
/// on. Clipboard arrivals and recordings never copy themselves.
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

    func testSettingSurvivesRestart() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        line.copiesNewCaptures = true
        XCTAssertTrue(f.line().copiesNewCaptures)
        line.copiesNewCaptures = false
        XCTAssertFalse(f.line().copiesNewCaptures)
    }
}
