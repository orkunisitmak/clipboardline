import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Recognition can be held off the main queue while the test edits/deletes
/// the record or starts a newer command. No user pasteboard is involved.
private final class ImageTextRecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var completed = false
    private let release = DispatchSemaphore(value: 0)
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didComplete: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func recognize(_ url: URL) throws -> String {
        lock.lock(); entered = true; lock.unlock()
        guard release.wait(timeout: .now() + 10) == .success else { throw HistoryFiles.Failure.unsafeFile }
        lock.lock(); completed = true; lock.unlock()
        return "Old image text"
    }
    func resume() { release.signal() }
}

@MainActor final class ImageTextCopyTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(15)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Image text copy did not finish")
    }
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    private func cached(_ text: String, for record: LibraryRecord, store: LibraryStore, fingerprint: String? = nil, path: String? = nil) throws {
        let url = try XCTUnwrap(record.fileURL), key = try XCTUnwrap(fingerprint ?? ImageSearchWorker.fingerprint(url))
        let connection = try LibraryDatabase(url: store.databaseURL, verify: false)
        try connection.execute("INSERT OR REPLACE INTO image_analysis VALUES(?,?,?,?,?,?,?)", [.text(record.id.uuidString), .text(path ?? url.path), .text(key), .text("vision-ocr-v1"), .text(text.searchFolded), .text(text), .blob(Data())])
    }
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("image-text-copy-tests-\(UUID())")) }
    private func copy(_ service: ImageTextCopy, id: UUID) -> ImageTextCopy.Outcome? {
        var result: ImageTextCopy.Outcome?
        service.copy(id) { result = $0 }
        wait { result != nil }
        return result
    }

    func testFreshCachedOCRCopiesWithoutRecognitionAndPreservesRecord() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let item = try store.captureImage(f.image()), before = try store.item(item.id)
        try cached("Saved image text\nİstanbul 8427", for: item, store: store)
        let board = pasteboard(); defer { board.releaseGlobally() }
        let service = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) },
            recognize: { _ in throw HistoryFiles.Failure.unsafeFile })
        XCTAssertEqual(copy(service, id: item.id), .copied)
        XCTAssertEqual(board.string(forType: .string), "Saved image text\nİstanbul 8427")
        XCTAssertEqual(try store.item(item.id), before)
    }

    func testStaleFingerprintAndMismatchedIndexPathRequireFreshRecognition() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let item = try store.captureImage(f.image()), url = try XCTUnwrap(item.fileURL)
        try cached("Old cached text", for: item, store: store)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: url.path)
        let board = pasteboard(); defer { board.releaseGlobally() }
        let service = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { _ in "Current pixels" })
        XCTAssertEqual(copy(service, id: item.id), .copied)
        XCTAssertEqual(board.string(forType: .string), "Current pixels")
        try cached("Wrong path text", for: item, store: store, path: url.path + ".old")
        XCTAssertEqual(copy(service, id: item.id), .copied)
        XCTAssertEqual(board.string(forType: .string), "Current pixels")
    }

    func testEmptyFailedAndUnavailableOCRLeaveExistingClipboardUntouched() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let item = try store.captureImage(f.image()), note = try store.createNote()
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(ClipboardTransfer.write(ClipboardTransfer.textItems(["Keep me"]), to: board))
        let before = board.changeCount
        let empty = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { _ in " \n\t" })
        XCTAssertEqual(copy(empty, id: item.id), .noText)
        XCTAssertEqual(copy(empty, id: note.id), .unavailable)
        XCTAssertEqual(copy(empty, id: UUID()), .unavailable)
        let failed = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { _ in throw HistoryFiles.Failure.unsafeFile })
        XCTAssertEqual(copy(failed, id: item.id), .failed)
        try cached("", for: item, store: store)
        XCTAssertEqual(copy(failed, id: item.id), .noText, "An empty current cache must not rerun OCR")
        try store.trash([item.id])
        XCTAssertEqual(copy(empty, id: item.id), .unavailable)
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "Keep me")
    }

    func testImageDeletedOrEditedDuringRecognitionCannotCopyStaleText() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let item = try store.captureImage(f.image()), gate = ImageTextRecognitionGate()
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(ClipboardTransfer.write(ClipboardTransfer.textItems(["Keep me"]), to: board))
        let before = board.changeCount
        let service = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { try gate.recognize($0) })
        var result: ImageTextCopy.Outcome?
        service.copy(item.id) { result = $0 }
        wait { gate.didEnter }
        try store.trash([item.id]); gate.resume()
        wait { result != nil }
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(board.changeCount, before)
        try store.restore([item.id])
        let editedGate = ImageTextRecognitionGate()
        let edited = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { try editedGate.recognize($0) })
        result = nil; edited.copy(item.id) { result = $0 }; wait { editedGate.didEnter }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: try XCTUnwrap(item.fileURL).path)
        editedGate.resume(); wait { result != nil }
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(board.changeCount, before)
    }

    func testCancelledAndSupersededRecognitionNeverOverwriteNewerCopy() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let old = try store.captureImage(f.image()), latest = try store.captureImage(f.image()), gate = ImageTextRecognitionGate()
        try cached("Latest cached text", for: latest, store: store)
        let board = pasteboard(); defer { board.releaseGlobally() }
        let service = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { try gate.recognize($0) })
        var obsoleteCallback = false
        service.copy(old.id) { _ in obsoleteCallback = true }
        wait { gate.didEnter }
        XCTAssertEqual(copy(service, id: latest.id), .copied)
        gate.resume(); wait { gate.didComplete }; settle()
        XCTAssertFalse(obsoleteCallback)
        XCTAssertEqual(board.string(forType: .string), "Latest cached text")
        let cancelledGate = ImageTextRecognitionGate()
        let cancelled = ImageTextCopy(store: store, writeText: { ClipboardTransfer.write(ClipboardTransfer.textItems([$0]), to: board) }, recognize: { try cancelledGate.recognize($0) })
        let before = board.changeCount
        cancelled.copy(old.id) { _ in obsoleteCallback = true }; wait { cancelledGate.didEnter }
        cancelled.cancel(); cancelledGate.resume(); wait { cancelledGate.didComplete }; settle()
        XCTAssertFalse(obsoleteCallback)
        XCTAssertEqual(board.changeCount, before)
    }
}
