import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class CopyLargeImageTests: HistoryTestCase {
    /// A valid 1x1 PNG with a text chunk that decoders skip, so the file is larger than `minimumBytes`.
    private func png(atLeast minimumBytes: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let base = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let iendLength = 12
        let type = Data("tEXt".utf8), body = Data("Comment\0".utf8) + Data(count: minimumBytes)
        let table = (0..<256).map { (n: UInt32) -> UInt32 in (0..<8).reduce(n) { c, _ in c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 } }
        var crc: UInt32 = 0xFFFF_FFFF
        (type + body).withUnsafeBytes { bytes in for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) } }
        func big(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]) }
        return base.dropLast(iendLength) + big(UInt32(body.count)) + type + body + big(~crc) + base.suffix(iendLength)
    }

    func testStoredImageOverTheCaptureLimitIsStillCopied() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let large = f.folder.appendingPathComponent("Large.png")
        let data = try png(atLeast: ClipboardWatcher.maximumDataBytes + 1024)
        try data.write(to: large)
        let board = NSPasteboard(name: .init("copy-large-\(UUID())")); defer { board.releaseGlobally() }
        let payload = try ClipboardTransfer.imageItems([large])
        XCTAssertTrue(ClipboardTransfer.write(payload, to: board))
        let copied = try XCTUnwrap(board.pasteboardItems?.first?.data(forType: .png))
        XCTAssertEqual(copied.count, data.count)
        XCTAssertGreaterThan(copied.count, ClipboardWatcher.maximumDataBytes)
        let image = try XCTUnwrap(NSBitmapImageRep(data: copied))
        XCTAssertEqual(image.pixelsWide, 1); XCTAssertEqual(image.pixelsHigh, 1)
    }
}
