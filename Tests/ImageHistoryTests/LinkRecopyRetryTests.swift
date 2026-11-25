import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class LinkRecopyRetryTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    func testCopyingAFailedLinkAgainFetchesItsPreviewRightAway() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
        var online = false, calls = 0
        let service = LinkMetadataService(store: store, enabled: { true }, fetch: { _ in
            calls += 1
            guard online else { throw URLError(.notConnectedToInternet) }
            return LinkMetadata(title: "Release notes")
        })
        let url = URL(string: "https://example.com/releases/1")!
        let first = try store.captureLink(url)
        service.request([first.id]); wait { service.pendingCount == 0 && calls == 1 }
        XCTAssertEqual(try store.item(first.id)?.metadataState, "failed")

        online = true
        let again = try store.captureLink(url)
        XCTAssertEqual(again.id, first.id)
        service.request([again.id]); wait { service.pendingCount == 0 && calls == 2 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try store.item(first.id)?.metadataState, "ready")
        XCTAssertEqual(try store.item(first.id)?.metadataTitle, "Release notes")
    }
}
