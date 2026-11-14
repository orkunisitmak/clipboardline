import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Marks are stored in the displayed image's orientation, in unit coordinates
/// with the origin at the bottom left. A zoom or a Retina screen never changes
/// either the document or the resolution of the exported image.
enum ImageMarkupTool: String, Codable, CaseIterable {
    case select, pen, marker, rectangle, ellipse, arrow, line, text
}

struct MarkupPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }

    func position(in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

/// A non-destructive crop in the orientation-correct original's unit space.
/// Keeping the bottom-left origin used by marks lets later edits recover the
/// full original without moving or rescaling any annotation.
struct MarkupCrop: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    static let full = Self(x: 0, y: 0, width: 1, height: 1)
    var isFullImage: Bool { self == .full }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) &&
            x >= 0 && y >= 0 && width > 0 && height > 0 &&
            width <= 1 && height <= 1 && x + width <= 1 && y + height <= 1
    }

    func rect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
               width: width * rect.width, height: height * rect.height)
    }
}

struct MarkupColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    static let red = Self(red: 1, green: 0.23, blue: 0.19)
    static let orange = Self(red: 1, green: 0.58, blue: 0)
    static let yellow = Self(red: 1, green: 0.84, blue: 0.04)
    static let green = Self(red: 0.19, green: 0.82, blue: 0.35)
    static let blue = Self(red: 0.04, green: 0.48, blue: 1)
    static let purple = Self(red: 0.69, green: 0.32, blue: 0.87)
    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)
    static let palette: [Self] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    fileprivate var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

struct ImageMarkupElement: Codable, Equatable, Identifiable {
    var id: UUID
    var tool: ImageMarkupTool
    var points: [MarkupPoint]
    var color: MarkupColor
    /// Fraction of the shorter displayed image dimension, independent of zoom.
    var lineWidth: Double
    var fill: Bool
    var text: String?
    var fontSize: Double

    init(id: UUID = UUID(), tool: ImageMarkupTool, points: [MarkupPoint], color: MarkupColor = .red,
         lineWidth: Double = 0.004, fill: Bool = false, text: String? = nil, fontSize: Double = 0.04) {
        self.id = id; self.tool = tool; self.points = points; self.color = color
        self.lineWidth = lineWidth; self.fill = fill; self.text = text; self.fontSize = fontSize
    }

    /// Includes enough room for the visible stroke and arrow head. Used for
    /// selection; it is deliberately independent of the preview's zoom level.
    func bounds(in rect: NSRect) -> NSRect {
        guard let first = points.first else { return .zero }
        let positions = points.map { $0.position(in: rect) }
        let minX = positions.map(\.x).min() ?? first.position(in: rect).x
        let minY = positions.map(\.y).min() ?? first.position(in: rect).y
        let maxX = positions.map(\.x).max() ?? minX
        let maxY = positions.map(\.y).max() ?? minY
        let scale = min(rect.width, rect.height)
        if tool == .text {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(1, fontSize * scale), weight: .medium)]
            let size = ((text ?? "") as NSString).size(withAttributes: attributes)
            return NSRect(origin: first.position(in: rect), size: size)
        }
        let inset = lineWidth * scale * (tool == .arrow ? 4 : 0.5)
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -inset, dy: -inset)
    }
}

struct ImageMarkupDocument: Codable, Equatable {
    static let maximumElements = 2_000
    static let maximumPoints = 200_000
    static let maximumPointsPerElement = 20_000
    static let maximumTextLength = 4_000

    var version: Int
    var elements: [ImageMarkupElement]
    var crop: MarkupCrop?
    var isEmpty: Bool { elements.isEmpty && (crop == nil || crop?.isFullImage == true) }

    init(version: Int = 1, elements: [ImageMarkupElement] = [], crop: MarkupCrop? = nil) {
        self.version = version; self.elements = elements; self.crop = crop
    }

    private enum CodingKeys: String, CodingKey { case version, elements, crop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        elements = try values.decode([ImageMarkupElement].self, forKey: .elements)
        crop = try values.decodeIfPresent(MarkupCrop.self, forKey: .crop)
        _ = try validated()
    }

    @discardableResult func validated() throws -> Self {
        guard version == 1, crop?.isValid != false, elements.count <= Self.maximumElements,
              Set(elements.map(\.id)).count == elements.count else { throw ImageMarkupError.invalidDocument }
        var pointCount = 0
        for element in elements {
            pointCount += element.points.count
            guard pointCount <= Self.maximumPoints, element.points.count <= Self.maximumPointsPerElement,
                  element.color.isValid, element.lineWidth.isFinite, (0.0001...0.25).contains(element.lineWidth),
                  element.fontSize.isFinite, (0.005...0.5).contains(element.fontSize),
                  element.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  (element.text?.unicodeScalars.count ?? 0) <= Self.maximumTextLength else { throw ImageMarkupError.invalidDocument }
            switch element.tool {
            case .select: throw ImageMarkupError.invalidDocument
            case .pen, .marker:
                guard !element.points.isEmpty else { throw ImageMarkupError.invalidDocument }
            case .rectangle, .ellipse, .arrow, .line:
                guard element.points.count == 2 else { throw ImageMarkupError.invalidDocument }
            case .text:
                guard element.points.count == 1, let text = element.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImageMarkupError.invalidDocument }
            }
        }
        return self
    }
}

enum ImageMarkupError: Error, LocalizedError, Equatable {
    case invalidDocument, unreadableImage, imageTooLarge, renderFailed
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return L("The image markup document is invalid.")
        case .unreadableImage: return L("This image could not be opened for markup.")
        case .imageTooLarge: return L("Markup supports images up to 80 megapixels.")
        case .renderFailed: return L("The marked image could not be rendered.")
        }
    }
}

enum ImageMarkupRenderer {
    static let maximumPixelCount = 80_000_000

    /// A fresh PNG at the source's orientation-correct resolution. The
    /// source is only ever read. In particular, transparent screenshots retain
    /// their transparency and no window chrome enters the exported pixels.
    static func render(sourceURL: URL, document: ImageMarkupDocument) throws -> Data {
        _ = try document.validated()
        let image = try sourceImage(sourceURL)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageMarkupError.renderFailed }
        let rect = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(document: document, in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let composite = context.makeImage() else { throw ImageMarkupError.renderFailed }
        let output: CGImage
        if let crop = document.crop, !crop.isFullImage {
            // CGImage cropping uses a top-left origin. Round the bottom-left
            // bounds outwards before converting Y so every selected source
            // pixel survives and even a sub-pixel crop produces one pixel.
            let selection = crop.rect(in: rect)
            let left = min(image.width - 1, max(0, Int(floor(selection.minX))))
            let bottom = min(image.height - 1, max(0, Int(floor(selection.minY))))
            let right = min(image.width, max(left + 1, Int(ceil(selection.maxX))))
            let top = min(image.height, max(bottom + 1, Int(ceil(selection.maxY))))
            let pixels = CGRect(x: left, y: image.height - top, width: right - left, height: top - bottom)
            guard let cropped = composite.cropping(to: pixels) else { throw ImageMarkupError.renderFailed }
            output = cropped
        } else { output = composite }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ImageMarkupError.renderFailed }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageMarkupError.renderFailed }
        return data as Data
    }

    static func sourceImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw ImageMarkupError.unreadableImage }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= 65_536, h <= 65_536, w <= maximumPixelCount / h else { throw ImageMarkupError.imageTooLarge }
        // Asking Image I/O for the source's maximum dimension applies all eight
        // EXIF orientations without reducing its pixel dimensions. "Always"
        // avoids accidentally using a small thumbnail embedded in a JPEG.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageMarkupError.unreadableImage }
        guard image.width > 0, image.height > 0, image.width <= maximumPixelCount / image.height else { throw ImageMarkupError.imageTooLarge }
        return image
    }

    /// Draws into the active AppKit graphics context. The caller's view must use
    /// AppKit's normal bottom-left origin, as does the full-resolution renderer.
    static func draw(document: ImageMarkupDocument, in rect: NSRect) { draw(elements: document.elements, in: rect) }

    static func draw(elements: [ImageMarkupElement], in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for element in elements { draw(element, in: rect) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(_ element: ImageMarkupElement, in rect: NSRect) {
        guard element.tool != .select, let first = element.points.first else { return }
        let points = element.points.map { $0.position(in: rect) }
        let start = first.position(in: rect), scale = min(rect.width, rect.height)
        let width = max(0.1, element.lineWidth * scale)
        let path = NSBezierPath()
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        let color = element.color.nsColor.withAlphaComponent(element.color.alpha * (element.tool == .marker ? 0.32 : 1))
        color.setStroke(); color.setFill()
        switch element.tool {
        case .select: return
        case .pen, .marker:
            if points.count == 1 {
                NSBezierPath(ovalIn: NSRect(x: start.x - width / 2, y: start.y - width / 2, width: width, height: width)).fill()
                return
            }
            path.move(to: start)
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()
        case .rectangle, .ellipse:
            guard let end = points.last, points.count >= 2 else { return }
            let box = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let shape = element.tool == .ellipse ? NSBezierPath(ovalIn: box) : NSBezierPath(rect: box)
            shape.lineWidth = width; shape.lineJoinStyle = .round
            if element.fill { shape.fill() } else { shape.stroke() }
        case .line, .arrow:
            guard let end = points.last, points.count >= 2 else { return }
            path.move(to: start); path.line(to: end); path.stroke()
            if element.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let distance = hypot(end.x - start.x, end.y - start.y)
                let length = min(max(width * 4, scale * 0.018), distance * 0.4)
                let head = NSBezierPath(); head.lineWidth = width; head.lineCapStyle = .round; head.lineJoinStyle = .round
                head.move(to: NSPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                head.line(to: end)
                head.line(to: NSPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                head.stroke()
            }
        case .text:
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(1, element.fontSize * scale), weight: .medium), .foregroundColor: color]
            ((element.text ?? "") as NSString).draw(at: start, withAttributes: attributes)
        }
    }
}
