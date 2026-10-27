import AppKit
import Combine

/// Text never enters preferences, diagnostics or network requests.
@MainActor
final class TextHistory: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        var text: String
        let capturedAt: Date
        var pinned: Bool
        /// User label; the clipboard value remains in `text` unchanged.
        var title: String? = nil
        var uploadedURL: String? = nil

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.capturedAt == rhs.capturedAt && lhs.pinned == rhs.pinned
                && lhs.title == rhs.title && lhs.uploadedURL == rhs.uploadedURL
                && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }
    @Published private(set) var entries: [Entry] = [] { didSet { invalidateDisplayProjection() } }
    @Published var favoritesOnly = false { didSet { if favoritesOnly != oldValue { invalidateDisplayProjection() } } }
    @Published private(set) var searchMatchingIDs: Set<UUID>? { didSet { invalidateDisplayProjection() } }
    @Published var scrollOffset: CGFloat = 0
    @Published var focusedID: UUID?
    @Published private(set) var selectedIDs = Set<UUID>() { didSet { if selectedIDs != oldValue { cachedSelectedEntries = nil } } }
    @Published private(set) var selecting = false
    private var selectionAnchor: UUID?
    @Published var notice: String?
    @Published private(set) var copiedIDs = Set<UUID>()
    private var copyFeedbackGeneration = 0
    private let defaults: UserDefaults
    let folder: URL
    private let now: () -> Date
    private let moveToTrash: (URL) throws -> URL
    private let copyTextOverride: ((String) -> Void)?
    private let library: LibraryStore?
    private var librarySubscription: AnyCancellable?
    private var writable = true
    var archive: URL { folder.appendingPathComponent("history.json") }
    // Filtering belongs to membership changes, not every scroll/hover/layout pass.
    // The unfiltered array shares its storage; filtered results remain reusable
    // until entries, the pinned filter or the literal search result changes.
    private var cachedDisplayEntries: [Entry]?
    private var cachedSelectedEntries: [Entry]?
    private func invalidateDisplayProjection() {
        cachedDisplayEntries = nil
        cachedSelectedEntries = nil
    }
    var displayEntries: [Entry] {
        guard favoritesOnly || searchMatchingIDs != nil else { return entries }
        if let cachedDisplayEntries { return cachedDisplayEntries }
        let result = entries.filter { (!favoritesOnly || $0.pinned) && (searchMatchingIDs?.contains($0.id) ?? true) }
        cachedDisplayEntries = result
        return result
    }
    func setSearchMatchingIDs(_ ids: Set<UUID>?, width: CGFloat) {
        guard searchMatchingIDs != ids else { return }
        searchMatchingIDs = ids; sanitizeFocus(); scroll(0, width: width)
    }
    var selectedEntries: [Entry] {
        guard !selectedIDs.isEmpty else { return [] }
        if let cachedSelectedEntries { return cachedSelectedEntries }
        let result = displayEntries.filter { selectedIDs.contains($0.id) }
        cachedSelectedEntries = result
        return result
    }
    var retentionDays: Int {
        HistoryRetention.days(.text, defaults: defaults)
    }

    init(defaults: UserDefaults, folder: URL, now: @escaping () -> Date = Date.init,
         moveToTrash: @escaping (URL) throws -> URL = HistoryFiles.systemTrash,
         copyText: ((String) -> Void)? = nil, library: LibraryStore? = nil, pruneOnLoad: Bool = true) {
        self.library = library
        self.defaults = defaults; self.folder = folder.standardizedFileURL
        self.now = now; self.moveToTrash = moveToTrash; copyTextOverride = copyText
        if let library {
            reloadFromLibrary()
            librarySubscription = library.$revision.dropFirst().sink { [weak self, weak library] _ in if library?.changedKinds.contains(.text) == true { self?.reloadFromLibrary() } }
            return
        }
        if FileManager.default.fileExists(atPath: archive.path) {
            do {
                guard safeFolder(), (try archive.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw HistoryFiles.Failure.unsafeFile
                }
                guard (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 32 * 1024 * 1024 else {
                    throw HistoryFiles.Failure.unsafeFile
                }
                let data = try Data(contentsOf: archive)
                let saved = try JSONDecoder().decode([Entry].self, from: data)
                var seen = Set<UUID>()
                entries = saved.filter { seen.insert($0.id).inserted && $0.text.utf8.count <= TextClipboardWatcher.maximumDataBytes }
            } catch { writable = false; notice = L("Text archive could not be opened; the existing file is kept") }
        }
        if pruneOnLoad { prune() }
    }

    private func reloadFromLibrary() {
        guard let library else { return }
        do {
            let updated = try library.shelfItems(.text).map { Entry(id: $0.id, text: $0.text ?? "", capturedAt: $0.createdAt, pinned: $0.favorite, title: $0.title.isEmpty ? nil : $0.title, uploadedURL: $0.uploadedURL) }
            if updated != entries { entries = updated; sanitizeFocus() }
        }
        catch { notice = L("Library could not be saved or opened") }
    }

    private func safeFolder() -> Bool { folder.resolvingSymlinksInPath().path == folder.path }
    @discardableResult
    func add(_ text: String) -> Bool {
        if let library { do { guard try library.captureText(text) != nil else { return false }; scrollOffset = 0; return true } catch { notice = error.localizedDescription; return false } }
        guard writable, !text.isEmpty, text.utf8.count <= TextClipboardWatcher.maximumDataBytes else { return false }
        let identity = TextIdentity.key(text)
        let matching = entries.filter { TextIdentity.key($0.text).utf8.elementsEqual(identity.utf8) }
        let newest = matching.reduce(nil as Entry?) { newest, candidate in
            guard let newest else { return candidate }
            return candidate.capturedAt > newest.capturedAt ? candidate : newest
        }
        var title = newest?.title
        if title?.isEmpty != false {
            title = matching.filter { $0.title?.isEmpty == false }
                .reduce(nil as Entry?) { newest, candidate in
                    guard let newest else { return candidate }
                    return candidate.capturedAt > newest.capturedAt ? candidate : newest
                }?.title
        }
        let latest = Entry(id: newest?.id ?? UUID(), text: text, capturedAt: now(),
                           pinned: matching.contains(where: \.pinned), title: title)
        let matchedIDs = Set(matching.map(\.id))
        let proposed = [latest] + entries.filter { !matchedIDs.contains($0.id) }
        var textFileRollback: (url: URL, data: Data)?
        do {
            if let newest { textFileRollback = try rewriteMaterializedText(newest, to: text) }
            guard save(proposed) else {
                if let rollback = textFileRollback { try? privateWrite(rollback.data, to: rollback.url) }
                return false
            }
        } catch { notice = L("Could not save text history"); return false }
        entries = proposed; scrollOffset = 0; sanitizeFocus()
        return true
    }
    private func rewriteMaterializedText(_ previous: Entry, to text: String) throws -> (url: URL, data: Data)? {
        let old = Data(previous.text.utf8), new = Data(text.utf8)
        guard old != new else { return nil }
        let file = folder.appendingPathComponent("Text \(previous.id).txt")
        let isLink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard FileManager.default.fileExists(atPath: file.path) || isLink else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard safeFolder(), values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
              try Data(contentsOf: file) == old else { throw HistoryFiles.Failure.unsafeFile }
        try privateWrite(new, to: file)
        return (file, old)
    }
    func togglePin(_ id: UUID) {
        if let library { do { try library.toggleFavorite([id]) } catch { notice = error.localizedDescription }; return }
        var proposed = entries
        guard let index = proposed.firstIndex(where: { $0.id == id }) else { return }
        proposed[index].pinned.toggle()
        if save(proposed) { entries = proposed }
        sanitizeFocus()
    }
    @discardableResult func updateText(_ id: UUID, to text: String) -> Bool {
        if let library { do { try library.update(id) { $0.text = text }; return true } catch { notice = L("Could not save text history"); return false } }
        guard writable, text.utf8.count <= TextClipboardWatcher.maximumDataBytes,
              let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if entries[index].text.utf8.elementsEqual(text.utf8) { return true }
        let previous = entries
        let file = folder.appendingPathComponent("Text \(id).txt")
        let materialized = FileManager.default.fileExists(atPath: file.path)
        do {
            if materialized {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      try Data(contentsOf: file) == Data(previous[index].text.utf8) else { throw HistoryFiles.Failure.unsafeFile }
            }
            var proposed = previous; proposed[index].text = text
            guard save(proposed) else { return false }
            if materialized {
                do { try privateWrite(Data(text.utf8), to: file) }
                catch { _ = save(previous); throw error }
            }
            entries = proposed; return true
        } catch { notice = L("Could not save text history"); return false }
    }
    func setFavoritesOnly(_ value: Bool) {
        favoritesOnly = value; scrollOffset = 0; cancelSelection()
    }
    func cancelSelection() {
        if !selectedIDs.isEmpty { selectedIDs.removeAll() }
        if focusedID != nil { focusedID = nil }
        selectionAnchor = nil
        if selecting { selecting = false }
    }
    func selectAll() {
        selecting = true; selectedIDs = Set(displayEntries.map(\.id)); focusedID = displayEntries.first?.id; selectionAnchor = focusedID
    }
    func select(_ id: UUID, toggle: Bool = false, extending: Bool = false, preservingSelection: Bool = false, width: CGFloat) {
        let displayed = displayEntries
        guard let index = displayed.firstIndex(where: { $0.id == id }) else { return }
        if extending, let anchor = selectionAnchor, let start = displayed.firstIndex(where: { $0.id == anchor }) {
            selectedIDs = Set(displayed[min(start,index)...max(start,index)].map(\.id))
        } else if toggle {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }; selectionAnchor = id
        } else if !preservingSelection || !selectedIDs.contains(id) { selectedIDs = [id]; selectionAnchor = id }
        focusedID = id; if extending || toggle { selecting = true }
        let left = Layout.x(index: index) - Layout.cardWidth / 2
        if left < scrollOffset { scrollOffset = max(0, left - Layout.edgePadding) }
        if left + Layout.cardWidth > scrollOffset + width { scrollOffset = left + Layout.cardWidth + Layout.edgePadding - width }
        scroll(0, width: width)
    }
    func moveSelection(_ delta: Int, width: CGFloat, extending: Bool = false) {
        let displayed = displayEntries
        guard !displayed.isEmpty else { return }
        let current = focusedID.flatMap { id in displayed.firstIndex(where: { $0.id == id }) }
        let index = current.map { max(0, min(displayed.count - 1, $0 + delta)) } ?? 0
        select(displayed[index].id, extending: extending, width: width)
    }
    func actionEntries(for id: UUID) -> [Entry] {
        selectedIDs.contains(id) && selectedEntries.count > 1 ? selectedEntries : entries.filter { $0.id == id }
    }
    func scroll(_ delta: CGFloat, width: CGFloat) {
        guard delta.isFinite else { return }
        let offset = max(0, min(Layout.maximumOffset(count: displayEntries.count, width: width), scrollOffset - delta))
        if offset != scrollOffset { scrollOffset = offset }
    }
    func prune() {
        if let library { do { try library.prune() } catch { notice = error.localizedDescription }; return }
        guard writable else { return }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86400)
        let expired = entries.filter { !$0.pinned && $0.capturedAt <= cutoff }
        trash(expired.map(\.id))
    }
    /// Explicit removals and expiry both leave recoverable plain-text copies in Trash.
    func trash(_ ids: [UUID]) {
        if let library { do { try library.trash(ids) } catch { notice = error.localizedDescription }; return }
        guard writable, !ids.isEmpty else { return }
        var removed = Set<UUID>()
        for entry in entries where ids.contains(entry.id) {
            do {
                try prepareFolder()
                let file = folder.appendingPathComponent("Text \(entry.id).txt")
                if FileManager.default.fileExists(atPath: file.path) {
                    guard (try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
                          (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                          try Data(contentsOf: file) == Data(entry.text.utf8) else { throw HistoryFiles.Failure.unsafeFile }
                } else { try privateWrite(Data(entry.text.utf8), to: file) }
                _ = try moveToTrash(file)
                removed.insert(entry.id)
            } catch { notice = L("Some text copies could not be moved to Trash") }
        }
        guard !removed.isEmpty else { return }
        let proposed = entries.filter { !removed.contains($0.id) }
        if save(proposed) { entries = proposed }
        sanitizeFocus()
    }
    @discardableResult func copy(_ id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return copyEntries([entry])
    }
    func copyAction(_ id: UUID) { copyEntries(actionEntries(for: id)) }
    @discardableResult func copySelection() -> Bool { copyEntries(selectedEntries) }
    @discardableResult func copyEntries(_ values: [Entry], to pasteboard: NSPasteboard? = nil) -> Bool {
        guard !values.isEmpty else { return false }
        if let copyTextOverride, pasteboard == nil { copyTextOverride(values.map(\.text).joined(separator: "\n\n")) }
        else if !ClipboardTransfer.write(ClipboardTransfer.textItems(values.map(\.text)), to: pasteboard ?? .general) {
            notice = L("Could not copy selected items"); return false
        }
        copiedIDs = Set(values.map(\.id)); copyFeedbackGeneration += 1
        try? library?.markCopied(values.map(\.id))
        let generation = copyFeedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copyFeedbackGeneration == generation { self?.copiedIDs.removeAll() }
        }
        return true
    }
    func materialize(_ entry: Entry) throws -> URL {
        guard writable else { throw HistoryFiles.Failure.unsafeFile }
        try prepareFolder()
        let file = folder.appendingPathComponent("Text \(entry.id).txt")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true,
                  try Data(contentsOf: file) == Data(entry.text.utf8) else { throw HistoryFiles.Failure.unsafeFile }
        } else { try privateWrite(Data(entry.text.utf8), to: file) }
        return file
    }
    func isRetained(_ id: UUID) -> Bool {
        guard let library, let item = try? library.item(id) else { return false }
        return item.retainedAt != nil
    }
    func removeFromShelf(_ id: UUID) {
        if let library { do { try library.removeFromShelf([id]) } catch { notice = error.localizedDescription } }
        else { trash([id]) }
    }
    func exportSources(_ values: [Entry]) throws -> [(url: URL, name: String)] {
        try values.map { entry in
            let url = try materialize(entry)
            return (url, url.lastPathComponent)
        }
    }
    func dragItems(_ id: UUID) -> [ShelfDragItem] {
        do {
            let entries = actionEntries(for: id)
            let combinedText = entries.map(\.text).joined(separator: "\n\n")
            return try entries.enumerated().map { index, entry in
                let file = try materialize(entry); let writer = NSPasteboardItem()
                // Text editors usually request one string for the entire drag.
                // File destinations still receive one independent URL per entry.
                if index == 0 { writer.setString(combinedText, forType: .string) }
                writer.setString(file.absoluteString, forType: .fileURL)
                let image = NSImage(size: NSSize(width: 140, height: 100), flipped: false) { rect in
                    NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
                    (String(entry.text.prefix(120)) as NSString).draw(in: rect.insetBy(dx: 10, dy: 10),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
                    return true
                }
                return ShelfDragItem(id: entry.id, sourceURL: file, writer: writer, image: image)
            }
        } catch { notice = L("Could not export copies"); return [] }
    }
    private func sanitizeFocus() {
        if let id = focusedID, !displayEntries.contains(where: { $0.id == id }) { focusedID = nil }
        let ids = Set(displayEntries.map(\.id)); selectedIDs.formIntersection(ids)
        if let id = selectionAnchor, !ids.contains(id) { selectionAnchor = nil }
    }
    private func prepareFolder() throws {
        guard safeFolder() else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    private func privateWrite(_ data: Data, to target: URL) throws {
        // A private staging file keeps contents private throughout atomic replacement.
        let stage = folder.appendingPathComponent(".write-\(UUID())")
        guard FileManager.default.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HistoryFiles.Failure.unsafeFile
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: stage)
        } else { try FileManager.default.moveItem(at: stage, to: target) }
    }
    private func save(_ proposed: [Entry]) -> Bool {
        guard writable else { return false }
        do {
            try prepareFolder()
            if FileManager.default.fileExists(atPath: archive.path),
               (try archive.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw HistoryFiles.Failure.unsafeFile }
            let data = try JSONEncoder().encode(proposed)
            guard data.count <= 32 * 1024 * 1024 else { notice = L("Text archive is full; new text was not saved"); return false }
            try privateWrite(data, to: archive)
            return true
        } catch { notice = L("Could not save text history"); return false }
    }
}
