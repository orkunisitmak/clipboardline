import AppKit

@MainActor enum LibraryTransfer {
    /// Every representation is prepared before the destination is touched.
    static func pasteboardItems(_ records: [LibraryRecord]) throws -> [NSPasteboardItem] {
        var textBytes = 0
        for record in records {
            textBytes += (record.text ?? record.originalURL ?? "").utf8.count
            guard textBytes <= 32 * 1024 * 1024 else { throw ClipboardTransfer.Failure.tooLarge }
        }
        if !records.isEmpty, records.allSatisfy({ $0.kind == .text }) { return ClipboardTransfer.textItems(records.compactMap(\.text)) }
        if !records.isEmpty, records.allSatisfy({ $0.kind == .link }) { return ClipboardTransfer.linkItems(records.compactMap(\.originalURL)) }
        // Mixed selections carry each item's native representation. A target
        // that reads only one item can consume only that item; no empty object
        // is used as a placeholder for later text entries.
        var items = [NSPasteboardItem](), totalImageBytes = 0
        for record in records {
            if record.kind == .image {
                guard let url = record.fileURL else { throw HistoryFiles.Failure.unsafeFile }
                let prepared = try ClipboardTransfer.imageItems([url])
                totalImageBytes += prepared.reduce(0, { $0 + ($1.data(forType: .png)?.count ?? 0) })
                guard totalImageBytes <= 128 * 1024 * 1024 else { throw ClipboardTransfer.Failure.tooLarge }
                items += prepared
            } else {
                let item = NSPasteboardItem()
                item.setString(record.text ?? record.originalURL ?? "", forType: .string)
                if record.kind == .link, let url = record.originalURL { item.setString(url, forType: .URL) }
                items.append(item)
            }
        }
        return items
    }
    static func materialize(_ record: LibraryRecord, store: LibraryStore) throws -> URL {
        if record.kind == .image { guard let url = record.fileURL, store.files.isRegularFile(url) else { throw HistoryFiles.Failure.unsafeFile }; return url }
        let folder = store.files.inbox.appendingPathComponent(record.kind == .text ? "Texts" : "Links", isDirectory: true)
        guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(record.kind == .text ? "Text \(record.id).txt" : "Link \(record.id).webloc")
        let data: Data
        if record.kind == .text { data = Data((record.text ?? "").utf8) }
        else { guard let url = record.originalURL else { throw HistoryFiles.Failure.unsafeFile }; data = try PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0) }
        if FileManager.default.fileExists(atPath: file.path) {
            guard store.files.isRegularFile(file), try Data(contentsOf: file) == data else { throw HistoryFiles.Failure.unsafeFile }
        } else { try store.writePrivate(data, to: file) }
        return file
    }
    static func exportSources(_ records: [LibraryRecord], store: LibraryStore) throws -> [(url: URL, name: String)] {
        try records.map { let file = try materialize($0, store: store); return (file, HistoryFiles.exportName(for: file, originalPath: $0.originalPath, title: $0.title)) }
    }
    static func dragItems(_ records: [LibraryRecord], store: LibraryStore) throws -> [ShelfDragItem] {
        let plain = records.compactMap { $0.kind == .text ? $0.text : $0.originalURL }.joined(separator: "\n\n")
        var wroteText = false
        return try records.map { record in
            let file = try materialize(record, store: store), writer = NSPasteboardItem()
            writer.setString(file.absoluteString, forType: .fileURL)
            // The native collection also supplies these IDs for local folder drops.
            writer.setString(record.id.uuidString, forType: NSPasteboard.PasteboardType("local.clipboardline.library-id"))
            if record.kind != .image {
                if !wroteText { writer.setString(plain, forType: .string); wroteText = true }
                if let url = record.originalURL { writer.setString(url, forType: .URL) }
            }
            return ShelfDragItem(id: record.id, sourceURL: file, writer: writer, image: NSImage(systemSymbolName: record.kind == .image ? "photo" : record.kind == .text ? "doc.text" : "link", accessibilityDescription: record.displayTitle))
        }
    }
}
