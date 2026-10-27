import Foundation

/// Only metadata is persisted. Expiry never touches the system clipboard.
@MainActor
final class ImageHistory {
    struct Entry: Codable, Equatable {
        let id: UUID
        let path: String
        let capturedAt: Date
        var pinned: Bool
        var originalPath: String?
        var title: String?
        var uploadedURL: String?
        var url: URL { URL(fileURLWithPath: path) }
        var exportFileName: String { HistoryFiles.exportName(for: url, originalPath: originalPath) }

        init(path: String, capturedAt: Date, pinned: Bool = false, originalPath: String? = nil, id: UUID = UUID(), title: String? = nil, uploadedURL: String? = nil) {
            self.id = id
            self.path = path
            self.capturedAt = capturedAt
            self.pinned = pinned
            self.originalPath = originalPath
            self.title = title
            self.uploadedURL = uploadedURL
        }

        private enum CodingKeys: String, CodingKey { case id, path, capturedAt, pinned, originalPath, title, uploadedURL }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            path = try values.decode(String.self, forKey: .path)
            capturedAt = try values.decode(Date.self, forKey: .capturedAt)
            pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            originalPath = try values.decodeIfPresent(String.self, forKey: .originalPath)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            uploadedURL = try values.decodeIfPresent(String.self, forKey: .uploadedURL)
        }
    }

    static let dayChoices = [1, 3, 7, 15, 30]
    static let defaultDays = 30
    private static let entriesKey = "imageHistoryV1"
    private static let daysKey = "historyRetentionDays"
    private let defaults: UserDefaults
    private let inbox: URL
    private let now: () -> Date
    let files: HistoryFiles
    private var legacyEntries: [Entry] = []
    private let library: LibraryStore?
    var entries: [Entry] {
        get {
            if let library {
                return ((try? library.shelfItems(.image)) ?? []).compactMap { item in
                    guard let path = item.path else { return nil }
                    return Entry(path: path, capturedAt: item.createdAt, pinned: item.favorite, originalPath: item.originalPath, id: item.id, title: item.title.isEmpty ? nil : item.title, uploadedURL: item.uploadedURL)
                }
            }
            return legacyEntries
        }
        set { legacyEntries = newValue }
    }

    var retentionDays: Int {
        let value = defaults.integer(forKey: Self.daysKey)
        return Self.dayChoices.contains(value) ? value : Self.defaultDays
    }

    init(defaults: UserDefaults, inbox: URL, now: @escaping () -> Date = Date.init,
         moveToTrash: @escaping (URL) throws -> URL = HistoryFiles.systemTrash, pruneOnLoad: Bool = true, library: LibraryStore? = nil) {
        self.library = library
        self.defaults = defaults
        self.inbox = inbox.standardizedFileURL
        self.now = now
        files = HistoryFiles(inbox: inbox, moveToTrash: moveToTrash)
        if library != nil { return }
        if let data = defaults.data(forKey: Self.entriesKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            var seen = Set<String>()
            entries = saved.filter { seen.insert($0.path).inserted }
        } else {
            // The old list was oldest first. Recover clipboard images that the
            // old screen-capacity limit removed, once, without resurrecting
            // deliberately removed entries on later launches.
            let paths = defaults.stringArray(forKey: "pegged") ?? []
            var seen = Set<String>()
            let urls = paths.map { URL(fileURLWithPath: $0) } + ownedClipboardFiles()
            entries = urls.enumerated().compactMap { index, url in
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return nil }
                let date = creationDate(url) ?? now().addingTimeInterval(Double(index - urls.count))
                return Entry(path: path, capturedAt: date)
            }.sorted { $0.capturedAt > $1.capturedAt }
            // A damaged preferences record must not strand protected copies.
            for url in files.files(in: files.favoritesFolder, matching: files.isFavoriteCopy)
            where !entries.contains(where: { $0.path == url.path }) {
                entries.append(Entry(path: url.standardizedFileURL.path, capturedAt: creationDate(url) ?? now(), pinned: true))
            }
        }
        if pruneOnLoad { prune() }
    }

    func add(_ url: URL) {
        if let library { do { try library.captureImage(url) } catch { library.notice = error.localizedDescription }; return }
        let path = url.standardizedFileURL.path
        guard !entries.contains(where: { $0.path == path }) else { return }
        entries.insert(Entry(path: path, capturedAt: now()), at: 0)
        save()
    }

    func remove(_ url: URL) {
        if let library { if let id = entries.first(where: { $0.url == url })?.id { do { try library.removeFromShelf([id]) } catch { library.notice = error.localizedDescription } }; return }
        entries.removeAll { $0.path == url.standardizedFileURL.path }
        save()
    }

    func clear() {
        if let library { do { try library.removeFromShelf(entries.filter { !$0.pinned }.map(\.id)) } catch { library.notice = error.localizedDescription }; return }
        entries.removeAll { !$0.pinned }
        save()
    }

    func setRetentionDays(_ days: Int) {
        guard Self.dayChoices.contains(days) else { return }
        defaults.set(days, forKey: Self.daysKey)
        prune()
    }

    @discardableResult
    func togglePin(_ url: URL, id: UUID? = nil) throws -> Entry? {
        if let library {
            guard let id = id ?? entries.first(where: { $0.url == url })?.id else { return nil }
            try library.toggleFavorite([id]); return entries.first { $0.id == id }
        }
        guard let index = entries.firstIndex(where: { $0.path == url.standardizedFileURL.path }) else { return nil }
        var entry = entries[index]
        if !entry.pinned && !files.isAppCopy(url) {
            let copy = try files.makeFavoriteCopy(of: url)
            entry = Entry(path: copy.path, capturedAt: entry.capturedAt, pinned: true, originalPath: entry.path, id: entry.id, title: entry.title)
        } else {
            entry.pinned.toggle()
        }
        entries[index] = entry
        save()
        return entry
    }

    func prune() {
        if let library { do { try library.prune() } catch { library.notice = error.localizedDescription }; return }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var removable = Set<String>()
        for entry in entries {
            if !FileManager.default.fileExists(atPath: entry.path) { removable.insert(entry.path); continue }
            guard !entry.pinned, entry.capturedAt <= cutoff else { continue }
            if files.isAppCopy(entry.url) {
                do { try files.trashAppCopy(entry.url); removable.insert(entry.path) }
                catch { log.error("Could not move an expired app copy to Trash") }
            } else { removable.insert(entry.path) }
        }
        entries.removeAll { removable.contains($0.path) }
        let trackedPaths = Set(entries.map(\.path))
        for url in ownedClipboardFiles() {
            if !trackedPaths.contains(url.standardizedFileURL.path),
               let date = creationDate(url), date <= cutoff {
                do { try files.trashAppCopy(url) }
                catch { log.error("Could not move an expired clipboard copy to Trash") }
            }
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
        // Keep the old path list current for a reversible app downgrade.
        defaults.set(entries.reversed().map(\.path), forKey: "pegged")
    }

    private func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private func ownedClipboardFiles() -> [URL] {
        files.files(in: inbox, matching: files.isClipboardCopy)
    }
}
