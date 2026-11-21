import AppKit

/// Build the entire transfer before replacing a pasteboard. Tests use a named
/// pasteboard; constructing these objects never reads the system clipboard.
@MainActor enum ClipboardTransfer {
    enum Failure: Error, LocalizedError {
        case unreadableImage, tooLarge
        var errorDescription: String? { self == .tooLarge ? L("This selection is too large to copy; select fewer items") : L("Selected files could not be read; nothing was copied") }
    }
    /// A stored image is copied at any size the shelf accepted; only the clipboard payload is bounded.
    private static let maximumPayloadBytes = 128 * 1024 * 1024
    static func imageItems(_ urls: [URL]) throws -> [NSPasteboardItem] {
        var total = 0
        return try urls.map { url in
            guard HistoryFiles(inbox: url.deletingLastPathComponent()).isRegularFile(url),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (isRecordingFile(url) || size <= maximumPayloadBytes) else { throw Failure.unreadableImage }
            if isRecordingFile(url) {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
            let png: Data
            if url.pathExtension.lowercased() == "png" { png = try Data(contentsOf: url) }
            else {
                // Other formats are decoded to make the PNG, so their header dimensions are bounded first.
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) > 0 else { throw Failure.unreadableImage }
                for frame in 0..<CGImageSourceGetCount(source) {
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
                          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                          width > 0, height > 0 else { throw Failure.unreadableImage }
                    guard width <= ImageMarkupRenderer.maximumPixelCount / height else { throw Failure.tooLarge }
                }
                guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw Failure.unreadableImage
                }
                png = data
            }
            total += png.count
            guard total <= maximumPayloadBytes else { throw Failure.tooLarge }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
    }
    static func textItems(_ values: [String]) -> [NSPasteboardItem] {
        guard !values.isEmpty else { return [] }
        // Most text editors request only the first plain-text representation.
        // It therefore contains every selected entry in shelf order.
        let item = NSPasteboardItem()
        item.setString(values.joined(separator: "\n\n"), forType: .string)
        return [item]
    }
    static func linkItems(_ urls: [String]) -> [NSPasteboardItem] {
        guard !urls.isEmpty else { return [] }
        let item = NSPasteboardItem()
        item.setString(urls.joined(separator: "\n\n"), forType: .string)
        if urls.count == 1 { item.setString(urls[0], forType: .URL) }
        return [item]
    }
    @MainActor @discardableResult
    static func write(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(items)
        if success, pasteboard.name == NSPasteboard.general.name {
            ClipboardWatcher.recordOwnCopy(changeCount: pasteboard.changeCount)
        }
        return success
    }
}

struct ShelfDragItem {
    let id: UUID
    let sourceURL: URL
    let writer: NSPasteboardWriting
    let image: NSImage?
}
