import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor private final class AdmissionClipboard: ClipboardSource {
    var count = 790000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var reads = 0
    var duringRead: (() -> Void)?
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? {
        reads += 1; let value = values[index][type]; duringRead?(); return value
    }
    func copy(_ values: [[NSPasteboard.PasteboardType: Data]]) { count += 1; self.values = values }
}

@MainActor final class ClipboardAdmissionTests: HistoryTestCase {
    private struct Contract: Decodable {
        struct TextCase: Decodable { let name: String; let value: String; let capture: Bool }
        let privateMarkers: [String]
        let textCases: [TextCase]
    }
    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/clipboard-admission.json")))
    }
    func testExternalMarkerContractRejectsEveryItemBeforeReadingTextLinksOrImages() throws {
        let oldOwn = ClipboardWatcher.ownChangeCount; defer { ClipboardWatcher.recordOwnCopy(changeCount: oldOwn) }
        for marker in try contract().privateMarkers {
            for separate in [false, true] {
                let source = AdmissionClipboard(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                var text = [String](), links = [URL](), images = [URL]()
                let image = ClipboardWatcher(source: source, folder: folder, onImage: { images.append($0) })
                let watcher = TextClipboardWatcher(source: source, onText: { text.append($0) }, onLink: { links.append($0) }, capturesLinks: { true })
                defer { watcher.stop(); image.stop(); try? FileManager.default.removeItem(at: folder) }
                image.start(); watcher.start()
                let type = NSPasteboard.PasteboardType(marker)
                for payload in [[NSPasteboard.PasteboardType.string: Data("synthetic private text".utf8)], [.URL: Data("https://example.invalid/private".utf8)], [.png: Data([1,2,3])]] {
                    source.copy(separate ? [payload, [type: Data()]] : [payload.merging([type: Data()]) { _, new in new }])
                    let reads = source.reads
                    image.check(); watcher.check()
                    XCTAssertEqual(source.reads, reads, marker)
                }
                XCTAssertTrue(text.isEmpty && links.isEmpty && images.isEmpty, marker)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), marker)
            }
        }
    }
    func testSharedTextContractSkipsOnlyWhitespaceAndKeepsAcceptedBytesExact() throws {
        let source = AdmissionClipboard(); var received = [String]()
        let watcher = TextClipboardWatcher(source: source, onText: { received.append($0) })
        defer { watcher.stop() }; watcher.start()
        for row in try contract().textCases {
            let before = received.count
            source.copy([[.string: Data(row.value.utf8)]])
            watcher.check()
            XCTAssertEqual(received.count, before + (row.capture ? 1 : 0), row.name)
            if row.capture { XCTAssertEqual(Array(received.last!.utf8), Array(row.value.utf8), row.name) }
        }
    }
    func testPrivateModeSkipsTextCopiedDuringPauseAndNeverReplaysIt() {
        let source = AdmissionClipboard(); var paused = true; var received = [String]()
        let watcher = TextClipboardWatcher(source: source, onText: { received.append($0) }, isPaused: { paused })
        defer { watcher.stop() }; watcher.start()
        source.copy([[.string: Data("during pause".utf8)]])
        watcher.check()
        XCTAssertTrue(received.isEmpty)
        paused = false
        watcher.check()
        XCTAssertTrue(received.isEmpty)
        source.copy([[.string: Data("after pause".utf8)]])
        watcher.check()
        XCTAssertEqual(received, ["after pause"])
    }

    func testPublicToPrivateReplacementDuringReadIsDiscardedAndFreshCopyCanFollow() {
        let source = AdmissionClipboard(); var received = [String]()
        let watcher = TextClipboardWatcher(source: source, onText: { received.append($0) })
        defer { watcher.stop() }; watcher.start()
        source.copy([[.string: Data("public synthetic".utf8)]])
        source.duringRead = { source.duringRead = nil; source.copy([[.string: Data("private synthetic".utf8), NSPasteboard.PasteboardType("com.agilebits.onepassword"): Data()]]) }
        watcher.check(); watcher.check()
        XCTAssertTrue(received.isEmpty)
        source.copy([[.string: Data("fresh synthetic".utf8)]]); watcher.check()
        XCTAssertEqual(received, ["fresh synthetic"])
    }
}
