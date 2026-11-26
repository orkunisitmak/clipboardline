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
        struct LinkedCase: Decodable { let name: String; let platforms: [String]?; let formats: [String: String]; let url: String?; let text: String? }
        let privateMarkers: [String]
        let linkedRepresentationCases: [LinkedCase]
        let textCases: [TextCase]
    }
    /// The macOS pasteboard types of a shared row; a row for another platform only is skipped.
    private func pasteboard(_ row: Contract.LinkedCase) throws -> [NSPasteboard.PasteboardType: Data]? {
        if let platforms = row.platforms, !platforms.contains("macos") { return nil }
        let types: [String: NSPasteboard.PasteboardType] = ["text/plain": .string, "text/html": .html]
        return try Dictionary(uniqueKeysWithValues: row.formats.map { (try XCTUnwrap(types[$0.key], row.name), Data($0.value.utf8)) })
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
    func testSharedLinkedRepresentationRowsSaveTheSingleLinkOrKeepTheExactText() throws {
        let source = AdmissionClipboard(); var texts = [String](), links = [URL](), linksOn = true
        let watcher = TextClipboardWatcher(source: source, onText: { texts.append($0) }, onLink: { links.append($0) }, capturesLinks: { linksOn })
        defer { watcher.stop() }; watcher.start()
        var ran = 0
        for row in try contract().linkedRepresentationCases {
            guard let item = try pasteboard(row) else { continue }
            ran += 1; texts = []; links = []
            linksOn = true; source.copy([item]); watcher.check()
            if let url = row.url { XCTAssertEqual(links.map(\.absoluteString), [url], row.name); XCTAssertTrue(texts.isEmpty, row.name) }
            else { XCTAssertEqual(texts, [try XCTUnwrap(row.text, row.name)], row.name); XCTAssertTrue(links.isEmpty, row.name) }
            // With link capture off the label stays text and the HTML is never read.
            guard let label = row.formats["text/plain"] else { continue }
            texts = []; links = []; linksOn = false; source.copy([item])
            let reads = source.reads; watcher.check()
            XCTAssertEqual(texts, [label], row.name); XCTAssertTrue(links.isEmpty, row.name); XCTAssertEqual(source.reads, reads + 1, row.name)
        }
        XCTAssertGreaterThanOrEqual(ran, 8)
    }
    func testHTMLAnchorIsTheLinkOnlyForARealHrefWhoseTextIsTheWholeLabel() {
        let source = AdmissionClipboard(); var texts = [String](), links = [URL]()
        let watcher = TextClipboardWatcher(source: source, onText: { texts.append($0) }, onLink: { links.append($0) }, capturesLinks: { true })
        defer { watcher.stop() }; watcher.start()
        func copied(_ label: String, _ html: String, url: Data? = nil) -> String? {
            texts = []; links = []
            var item: [NSPasteboard.PasteboardType: Data] = [.string: Data(label.utf8), .html: Data(html.utf8)]
            item[.URL] = url
            source.copy([item]); watcher.check()
            XCTAssertEqual(texts.count + links.count, 1, html)
            return links.first?.absoluteString
        }
        let anchor = "<a href=\"https://example.com/docs\">docs</a>"
        XCTAssertEqual(copied("docs", anchor), "https://example.com/docs")
        XCTAssertEqual(copied(" docs\r\n", anchor), "https://example.com/docs")
        XCTAssertNil(copied("the docs", anchor)); XCTAssertEqual(texts, ["the docs"])
        XCTAssertNil(copied("docs.", anchor))
        XCTAssertEqual(copied("Read docs", "<a\thref = https://example.com/unquoted >Read docs</a>"), "https://example.com/unquoted")
        XCTAssertEqual(copied("Read docs", "<a href=\"https://example.com/first\" href=\"https://example.com/second\">Read docs</a>"), "https://example.com/first")
        XCTAssertEqual(copied("Read docs", "<a name=\"top\"></a><a href=\"https://example.com/named\">Read docs</a>"), "https://example.com/named")
        XCTAssertEqual(copied("Read docs", "<a href=\"https://example.com/cut\">Read docs"), "https://example.com/cut")
        for html in ["<span data-x=\"<a href=https://example.com/in-value>\">Read docs</span>", "<abbr href=\"https://example.com/abbr\">Read docs</abbr>",
                     "<a xhref=\"https://example.com/x\" data-href=\"https://example.com/data\">Read docs</a>", "<a href=\"https://example.com/open>Read docs</a>",
                     "<a href=\"https://example.com/a b\">Read docs</a>", "<a href=\"https://user" + ":secret@example.com/\">Read docs</a>",
                     String(repeating: "<a \"", count: 250_000)] {
            XCTAssertNil(copied("Read docs", html), String(html.prefix(80))); XCTAssertEqual(texts, ["Read docs"])
        }
        // A label that is itself an address keeps the anchor's destination; in a paragraph it stays the copied address.
        XCTAssertEqual(copied("https://example.com/shown", "<a href=\"https://example.com/target\">https://example.com/shown</a>"), "https://example.com/target")
        XCTAssertEqual(copied("https://example.com/shown", "<p>See <a href=\"https://example.com/target\">this</a></p>"), "https://example.com/shown")
        // NSPasteboard.URL stays first, and an unusable one falls through to the HTML.
        XCTAssertEqual(copied("docs", anchor, url: Data("https://example.com/native".utf8)), "https://example.com/native")
        XCTAssertEqual(copied("docs", anchor, url: Data("file:///private/report.pdf".utf8)), "https://example.com/docs")
    }
    func testClipboardReplacedWhileReadingHTMLAdmitsNothing() {
        let source = AdmissionClipboard(); var received = 0
        let watcher = TextClipboardWatcher(source: source, onText: { _ in received += 1 }, onLink: { _ in received += 1 }, capturesLinks: { true })
        defer { watcher.stop() }; watcher.start()
        source.copy([[.string: Data("docs".utf8), .html: Data("<a href=\"https://example.com/late\">docs</a>".utf8)]])
        var reads = 0
        source.duringRead = { reads += 1; if reads == 2 { source.count += 1 } }
        watcher.check(); source.duringRead = nil
        XCTAssertEqual(reads, 2); XCTAssertEqual(received, 0)
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
