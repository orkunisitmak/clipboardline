import AppKit
import Carbon
import ImageIO
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class AreaCaptureTests: HistoryTestCase {
    func testCaptureAreaShortcutIsOffUntilChosenAndPersistsOffAndCustomValues() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        XCTAssertNil(line.captureAreaShortcut, "A global key is never taken before the user chooses it")
        let standard = Line.standardCaptureAreaShortcut
        XCTAssertEqual(standard.title, "⌘9")
        XCTAssertTrue(standard.isValid)
        line.saveCaptureAreaShortcut(standard)
        XCTAssertEqual(f.line().captureAreaShortcut, standard)
        line.saveCaptureAreaShortcut(nil)
        XCTAssertNil(line.captureAreaShortcut); XCTAssertNil(f.line().captureAreaShortcut)
        let custom = KeyShortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, keyLabel: "4")
        line.saveCaptureAreaShortcut(custom)
        XCTAssertEqual(f.line().captureAreaShortcut, custom)
        let plain = KeyShortcut(keyCode: kVK_ANSI_9, modifiers: 0, keyLabel: "9")
        line.saveCaptureAreaShortcut(plain)
        XCTAssertEqual(f.line().captureAreaShortcut, custom, "A plain key can never become a global capture shortcut")
        f.defaults.set(Data("invalid shortcut data".utf8), forKey: "captureAreaShortcut")
        XCTAssertNil(line.captureAreaShortcut, "Corrupt data must not register a different hotkey silently")
    }

    func testPixelRectFlipsToImageOriginScalesAndRoundsOutwards() throws {
        // A 2× display: 1000×500 points frozen into 2000×1000 pixels.
        let view = CGSize(width: 1000, height: 500)
        let bottomLeft = try XCTUnwrap(AreaCapture.pixelRect(for: CGRect(x: 0, y: 0, width: 100, height: 50),
            viewSize: view, imageWidth: 2000, imageHeight: 1000))
        XCTAssertEqual(bottomLeft, CGRect(x: 0, y: 900, width: 200, height: 100))
        let topRight = try XCTUnwrap(AreaCapture.pixelRect(for: CGRect(x: 900, y: 450, width: 100, height: 50),
            viewSize: view, imageWidth: 2000, imageHeight: 1000))
        XCTAssertEqual(topRight, CGRect(x: 1800, y: 0, width: 200, height: 100))
        let fractional = try XCTUnwrap(AreaCapture.pixelRect(for: CGRect(x: 10.3, y: 20.2, width: 5.1, height: 5.1),
            viewSize: view, imageWidth: 2000, imageHeight: 1000))
        XCTAssertEqual(fractional, CGRect(x: 20, y: 949, width: 11, height: 11))
    }

    func testPixelRectStaysInsideTheImageAndRejectsEmptyAreas() throws {
        let view = CGSize(width: 100, height: 100)
        let clamped = try XCTUnwrap(AreaCapture.pixelRect(for: CGRect(x: -10, y: -10, width: 200, height: 200),
            viewSize: view, imageWidth: 100, imageHeight: 100))
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(AreaCapture.pixelRect(for: CGRect(x: 200, y: 200, width: 10, height: 10), viewSize: view, imageWidth: 100, imageHeight: 100))
        XCTAssertNil(AreaCapture.pixelRect(for: .zero, viewSize: view, imageWidth: 100, imageHeight: 100))
        XCTAssertNil(AreaCapture.pixelRect(for: CGRect(x: 0, y: 0, width: 10, height: 10), viewSize: .zero, imageWidth: 100, imageHeight: 100))
    }

    func testCopiedCaptureIsATemporaryAppCopyThatFliesFromWhereItWasTaken() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemRed.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let png = try XCTUnwrap(AreaCapture.pngData(try XCTUnwrap(context.makeImage())))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 4); XCTAssertEqual(decoded.height, 3)

        let rect = CGRect(x: 40, y: 60, width: 320, height: 200)
        let url = try AreaCapture.writeAppCopy(png, rect: rect, folder: f.inbox)
        XCTAssertTrue(HistoryFiles(inbox: f.inbox).isAppCopy(url), "Captures follow the clipboard copy lifecycle")
        XCTAssertEqual(try Data(contentsOf: url), png)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        if !NSScreen.screens.isEmpty {
            XCTAssertEqual(captureRect(of: url), rect, "The stored capture area reads back for the flight to the line")
        }
    }

    func testMarksAreDrawnIntoTheKeptPixelsAtFullResolution() throws {
        // A white 40×20 "display"; a filled red rectangle covers its left half.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); source.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let display = try XCTUnwrap(source.makeImage())
        let mark = ImageMarkupElement(tool: .rectangle, points: [MarkupPoint(x: 0, y: 0), MarkupPoint(x: 0.5, y: 1)],
                                      color: MarkupColor(red: 1, green: 0, blue: 0), fill: true)
        // Keep the middle half: its left part is marked, its right part is not.
        let kept = try XCTUnwrap(AreaCapture.render(display, pixels: CGRect(x: 10, y: 0, width: 20, height: 20), elements: [mark]))
        XCTAssertEqual(kept.width, 20); XCTAssertEqual(kept.height, 20)
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        let read = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let reader = CGContext(data: buffer.baseAddress, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            reader.draw(kept, in: CGRect(x: 0, y: 0, width: 20, height: 20))
            return true
        }
        XCTAssertTrue(read)
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * 20 + x) * 4; return Array(pixels[i..<i + 3]) }
        XCTAssertEqual(rgb(5, 10), [255, 0, 0], "The mark lands where it was drawn on the display")
        XCTAssertEqual(rgb(15, 10), [255, 255, 255])
        // Without marks the pixels are the display's own, untouched.
        let plain = try XCTUnwrap(AreaCapture.render(display, pixels: CGRect(x: 10, y: 0, width: 20, height: 20), elements: []))
        XCTAssertEqual(plain.width, 20); XCTAssertEqual(plain.height, 20)
    }

    func testSuggestedSaveNameIsReadableAndSortable() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 3
        components.hour = 14; components.minute = 5; components.second = 9
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        let name = AreaCapture.suggestedFileName(date: date)
        XCTAssertTrue(name.hasSuffix(" 2026-11-03 14.05.09.png"), name)
    }
}
