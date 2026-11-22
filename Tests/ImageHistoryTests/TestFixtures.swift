import AppKit
import ImageIO
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

func fixtureTrash(_ folder: URL) -> (URL) throws -> URL {
    { url in
        let trash = folder.appendingPathComponent(".test-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appendingPathComponent("\(UUID())-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

@MainActor
final class SyntheticFixture {
    var date = Date()
    let suite = "favorites-tests-\(UUID())"
    let defaults: UserDefaults
    let folder: URL
    init(folderRoot: URL? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = (folderRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(true, forKey: "soundOff")
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    var inbox: URL { folder.appendingPathComponent("Screenshots") }
    private var imageCount: UInt16 = 0
    /// Each call draws different pixels unless `identicalPixels` is set, because identical copies are one Library item.
    func image(owned: Bool = true, name: String? = nil, identicalPixels: Bool = false) throws -> URL {
        imageCount &+= 1
        let dir = owned ? inbox : folder.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name ?? (owned ? "Clipboard \(UUID()).png" : "Screenshot \(UUID()).png"))
        let pixels: [UInt8] = identicalPixels ? [40, 160, 210, 255] : [UInt8(imageCount & 255), UInt8(imageCount >> 8), 210, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 1),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
    func line() -> Line {
        Line(defaults: defaults, inbox: inbox, now: { self.date }, breeze: false, moveToTrash: fixtureTrash(folder), copyImage: { _ in }, copyText: { _ in })
    }
    func history() -> ImageHistory {
        ImageHistory(defaults: defaults, inbox: inbox, now: { self.date }, moveToTrash: fixtureTrash(folder))
    }
    func texts() -> TextHistory {
        TextHistory(defaults: defaults, folder: inbox.appendingPathComponent("Texts"), now: { self.date }, moveToTrash: fixtureTrash(folder))
    }
}
