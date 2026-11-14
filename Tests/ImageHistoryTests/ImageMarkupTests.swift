import AppKit
import ImageIO
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ImageMarkupTests: HistoryTestCase {
    private var temporary: [URL] = []

    func testMarkupErrorMessagesAreTranslatedInEveryCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/Tendedero/Resources")
        let folders = try FileManager.default.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".lproj") }
        XCTAssertGreaterThan(folders.count, 1)
        // Catalog keys are the English source strings; errorDescription itself may already be translated.
        let messages = ["The image markup document is invalid.", "This image could not be opened for markup.",
                        "Markup supports images up to 80 megapixels.", "The marked image could not be rendered."]
        for message in messages {
            for folder in folders {
                let table = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent(folder).appendingPathComponent("Localizable.strings")) as? [String: String])
                XCTAssertNotNil(table[message], "\(folder) has no entry for \(message)")
            }
        }
    }
    private func cleanup() {
        for url in temporary { try? FileManager.default.removeItem(at: url) }
        temporary = []
    }

    private func assertThrows<T>(_ expression: @autoclosure () throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) {
        do { _ = try expression(); XCTAssertTrue(false, "Expected an error", file: file, line: line) }
        catch { handler(error) }
    }

    private func source(width: Int = 200, height: Int = 120, transparent: Bool = false,
                        orientation: Int? = nil, type: String = "public.png", quadrants: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("markup-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); temporary.append(directory)
        let url = directory.appendingPathComponent(type == "public.tiff" ? "source.tiff" : "source.png")
        let color: [UInt8] = transparent ? [0, 0, 0, 0] : [255, 255, 255, 255]
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
        let data = Data((0..<(width * height)).flatMap { index -> [UInt8] in
            quadrants ? colors[(index / width < height / 2 ? 0 : 2) + (index % width < width / 2 ? 0 : 1)] : color
        })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Samples an image using bottom-left Core Graphics coordinates without
    /// relying on the decoder's native byte order or color model.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[$0]) }
    }

    private func element(_ tool: ImageMarkupTool, _ points: [(Double, Double)], color: MarkupColor = .red,
                         width: Double = 0.025, fill: Bool = false, text: String? = nil) -> ImageMarkupElement {
        ImageMarkupElement(tool: tool, points: points.map { MarkupPoint(x: $0.0, y: $0.1) }, color: color,
                           lineWidth: width, fill: fill, text: text, fontSize: 0.2)
    }

    func testDocumentRoundTripPreservesAllVectorToolsAndStyles() throws {
        defer { cleanup() }
        let tools: [ImageMarkupTool] = [.pen, .marker, .rectangle, .ellipse, .arrow, .line, .text]
        let marks = tools.map { element($0, $0 == .text ? [(0.2, 0.4)] : [(0.2, 0.2), (0.8, 0.8)], color: .blue, fill: true, text: "İstanbul ✓") }
        let document = ImageMarkupDocument(elements: marks)
        XCTAssertEqual(try JSONDecoder().decode(ImageMarkupDocument.self, from: JSONEncoder().encode(document)), document)
        XCTAssertFalse(document.isEmpty)
        XCTAssertTrue(ImageMarkupDocument().isEmpty)
    }

    func testValidationRejectsNonFiniteOutOfRangeAndMalformedElements() throws {
        defer { cleanup() }
        let valid = element(.line, [(0.1, 0.2), (0.9, 0.8)])
        var bad = valid; bad.points[0].x = .infinity
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.points[0].y = -0.01
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.points[1].x = 1.01
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.color.alpha = .nan
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.lineWidth = 0
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.fontSize = 100
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.points.removeLast()
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        bad = valid; bad.tool = .select
        assertThrows(try ImageMarkupDocument(elements: [bad]).validated())
        assertThrows(try ImageMarkupDocument(version: 2).validated())
        assertThrows(try ImageMarkupDocument(elements: [valid, valid]).validated())
        assertThrows(try ImageMarkupDocument(elements: [element(.text, [(0.5, 0.5)], text: " \n ")]).validated())
    }

    func testDecodeAndRendererRejectInvalidStoredDocuments() throws {
        defer { cleanup() }
        let valid = ImageMarkupDocument(elements: [element(.pen, [(0.1, 0.1)])])
        let encoded = try JSONEncoder().encode(valid)
        let string = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let corrupt = Data(string.replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8)
        assertThrows(try JSONDecoder().decode(ImageMarkupDocument.self, from: corrupt))
        assertThrows(try ImageMarkupRenderer.render(sourceURL: source(), document: ImageMarkupDocument(version: 99)))
    }

    func testDocumentBoundsPreventHugePathsAndText() throws {
        defer { cleanup() }
        let point = MarkupPoint(x: 0.5, y: 0.5)
        var mark = element(.pen, [(0.5, 0.5)])
        mark.points = Array(repeating: point, count: ImageMarkupDocument.maximumPointsPerElement + 1)
        assertThrows(try ImageMarkupDocument(elements: [mark]).validated())
        mark.points = Array(repeating: point, count: ImageMarkupDocument.maximumPointsPerElement)
        var many = (0..<11).map { _ in mark }
        for index in many.indices { many[index].id = UUID() }
        assertThrows(try ImageMarkupDocument(elements: many).validated())
        let tooMany = (0...ImageMarkupDocument.maximumElements).map { _ in element(.pen, [(0.5, 0.5)]) }
        assertThrows(try ImageMarkupDocument(elements: tooMany).validated())
        assertThrows(try ImageMarkupDocument(elements: [element(.text, [(0.5, 0.5)], text: String(repeating: "x", count: 4_001))]).validated())
    }

    func testRenderRetainsFullResolutionAndNeverMutatesSource() throws {
        defer { cleanup() }
        let url = try source(width: 1600, height: 900), original = try Data(contentsOf: url)
        let mark = element(.line, [(0.1, 0.5), (0.9, 0.5)])
        let rendered = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: ImageMarkupDocument(elements: [mark])))
        XCTAssertEqual(rendered.width, 1600); XCTAssertEqual(rendered.height, 900)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let center = try pixel(rendered, 800, 450)
        XCTAssertTrue(center[0] > 240 && center[1] < 90 && center[2] < 90)
        XCTAssertEqual(try pixel(rendered, 800, 90), [255, 255, 255, 255])
    }

    func testEmptyDocumentRetainsTransparencyAndPixels() throws {
        defer { cleanup() }
        let url = try source(width: 80, height: 60, transparent: true)
        let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: .init()))
        XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 60)
        XCTAssertEqual(try pixel(image, 40, 30), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(image, 0, 0), [0, 0, 0, 0])
    }

    func testMarkerIsTranslucentWhilePenIsOpaque() throws {
        defer { cleanup() }
        let url = try source(width: 200, height: 200, transparent: true)
        let document = ImageMarkupDocument(elements: [element(.marker, [(0.1, 0.3), (0.9, 0.3)], color: .yellow, width: 0.08),
            element(.pen, [(0.1, 0.7), (0.9, 0.7)], width: 0.04)])
        let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: document))
        let marker = try pixel(image, 100, 60), pen = try pixel(image, 100, 140)
        XCTAssertTrue((75...88).contains(marker[3]), "Marker should have 32% opacity: \(marker)")
        XCTAssertEqual(pen[3], 255)
        XCTAssertEqual(try pixel(image, 100, 100)[3], 0)
    }

    func testNormalizedStrokeAndPositionScaleWithImageResolution() throws {
        defer { cleanup() }
        let document = ImageMarkupDocument(elements: [element(.line, [(0.2, 0.5), (0.8, 0.5)], width: 0.1)])
        for size in [100, 400] {
            let image = try decoded(ImageMarkupRenderer.render(sourceURL: source(width: size, height: size, transparent: true), document: document))
            XCTAssertEqual(try pixel(image, size / 2, size / 2)[3], 255)
            XCTAssertEqual(try pixel(image, size / 2, size / 2 + size / 25)[3], 255)
            XCTAssertEqual(try pixel(image, size / 2, size / 2 + size / 12)[3], 0)
            XCTAssertEqual(try pixel(image, size / 10, size / 2)[3], 0)
        }
    }

    func testEllipseAndRectangleFillRespectHollowCentersAndLayerOrder() throws {
        defer { cleanup() }
        let url = try source(width: 200, height: 200, transparent: true)
        let hollow = ImageMarkupDocument(elements: [element(.ellipse, [(0.2, 0.2), (0.8, 0.8)], width: 0.04)])
        let ellipse = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: hollow))
        XCTAssertEqual(try pixel(ellipse, 100, 100)[3], 0)
        XCTAssertTrue(try pixel(ellipse, 100, 40)[3] > 200)
        let layered = ImageMarkupDocument(elements: [element(.ellipse, [(0.1, 0.1), (0.9, 0.9)], fill: true),
            element(.rectangle, [(0.3, 0.3), (0.7, 0.7)], color: .blue, fill: true)])
        let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: layered))
        let center = try pixel(image, 100, 100)
        XCTAssertTrue(center[2] > 240 && center[0] < 30)
        let outside = try pixel(image, 40, 100)
        XCTAssertTrue(outside[0] > 240 && outside[2] < 90)
    }

    func testArrowIncludesVisibleHeadAndSinglePointPenMakesDot() throws {
        defer { cleanup() }
        let url = try source(width: 200, height: 200, transparent: true)
        let document = ImageMarkupDocument(elements: [element(.arrow, [(0.2, 0.5), (0.8, 0.5)], width: 0.025),
            element(.pen, [(0.2, 0.2)], color: .blue, width: 0.08)])
        let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: document))
        XCTAssertTrue(try pixel(image, 145, 108)[3] > 100, "Arrow head should extend above the line")
        XCTAssertEqual(try pixel(image, 100, 108)[3], 0)
        XCTAssertEqual(try pixel(image, 40, 40)[3], 255)
        XCTAssertEqual(try pixel(image, 40, 60)[3], 0)
    }

    func testUnicodeTextRendersAtImageCoordinates() throws {
        defer { cleanup() }
        let url = try source(width: 300, height: 200, transparent: true)
        let document = ImageMarkupDocument(elements: [element(.text, [(0.1, 0.2)], text: "İyi ✓")])
        let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: document))
        var markedPixels = 0
        for y in stride(from: 40, to: 95, by: 2) {
            for x in stride(from: 30, to: 150, by: 2) where try pixel(image, x, y)[3] > 0 { markedPixels += 1 }
        }
        XCTAssertTrue(markedPixels > 60)
        XCTAssertEqual(try pixel(image, 10, 10)[3], 0)
    }

    func testEXIFRotationUsesDisplayedOrientationWithoutDownsampling() throws {
        defer { cleanup() }
        // Source corners, in file order: red, green / blue, yellow. These
        // expected corners cover rotation and mirroring, not merely dimensions.
        let colors = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
        let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                        [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
        for orientation in 1...8 {
            let url = try source(width: 90, height: 50, orientation: orientation, type: "public.tiff", quadrants: true)
            let image = try decoded(ImageMarkupRenderer.render(sourceURL: url, document: .init()))
            XCTAssertEqual(image.width, orientation >= 5 ? 50 : 90)
            XCTAssertEqual(image.height, orientation >= 5 ? 90 : 50)
            let corners = expected[orientation - 1]
            XCTAssertEqual(try pixel(image, 5, image.height - 6), colors[corners[0]])
            XCTAssertEqual(try pixel(image, image.width - 6, image.height - 6), colors[corners[1]])
            XCTAssertEqual(try pixel(image, 5, 5), colors[corners[2]])
            XCTAssertEqual(try pixel(image, image.width - 6, 5), colors[corners[3]])
        }
    }

    func testSourceErrorsAndSelectionBoundsArePredictable() throws {
        defer { cleanup() }
        assertThrows(try ImageMarkupRenderer.render(sourceURL: URL(fileURLWithPath: "/this-image-does-not-exist.png"), document: .init()))
        let mark = element(.rectangle, [(0.2, 0.3), (0.8, 0.7)], width: 0.02)
        let bounds = mark.bounds(in: NSRect(x: 10, y: 20, width: 200, height: 100))
        XCTAssertEqual(bounds, NSRect(x: 49, y: 49, width: 122, height: 42))
    }

    func testMalformedOversizedPNGIsRejected() throws {
        defer { cleanup() }
        // Replace the PNG IHDR dimensions with a 100-megapixel declaration.
        // Pixel data stays tiny; Image I/O may reject its inconsistent scanlines
        // before exposing dimensions. Both rejection paths are acceptable.
        let url = try source(width: 20, height: 20)
        var data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "IHDR")
        func write(_ number: UInt32, at offset: Int) {
            for index in 0..<4 { data[offset + index] = UInt8((number >> ((3 - index) * 8)) & 255) }
        }
        write(20_000, at: 16); write(5_000, at: 20)
        var crc: UInt32 = 0xffffffff
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        write(crc ^ 0xffffffff, at: 29); try data.write(to: url)
        assertThrows(try ImageMarkupRenderer.render(sourceURL: url, document: .init())) {
            XCTAssertTrue([ImageMarkupError.imageTooLarge, .unreadableImage].contains($0 as? ImageMarkupError ?? .renderFailed))
        }
    }
}
