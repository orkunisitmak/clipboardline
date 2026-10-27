import Foundation
import Combine
import CryptoKit
import Darwin

enum LibraryKind: String, Codable, CaseIterable { case image, text, link }
/// Capture versions protect a recopy that reuses a deduplicated identity.
struct UnsavedHistorySnapshot: Equatable {
    let kind: LibraryKind?
    let ids: [UUID]
    let captures: [UUID: String]
}
struct LibraryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: LibraryKind
    var createdAt: Date
    var updatedAt: Date
    var lastCopiedAt: Date?
    var lastCapturedAt: Date?
    /// Optional for existing libraries; unrelated edits preserve this value.
    var captureRevision: UUID?
    /// A recoverable-trash generation, independent of capture identity. Older
    /// records need no migration; every new trash transition gets a fresh value.
    var trashRevision: UUID?
    var retainedAt: Date?
    var favorite = false
    var onShelf = true
    var deletedAt: Date?
    var title = ""
    var note = ""
    var text: String?
    var path: String?
    var originalPath: String?
    /// Vectors are separate from the full-resolution flattened PNG used by
    /// copy/export/OCR. The first unmarked pixels remain in a managed file.
    var imageMarkup: ImageMarkupDocument?
    var markupBasePath: String?
    /// First private recording bytes survive every later trim. originalPath
    /// remains filename/provenance metadata and is never used as a backup.
    var recordingOriginalPath: String?
    var originalURL: String?
    var normalizedURL: String?
    var thumbnailPath: String?
    var metadataTitle: String?
    var author: String?
    var metadataState = "pending"
    var metadataAttemptedAt: Date?
    var uploadedURL: String?
    var uploadedAt: Date?
    var displayTitle: String {
        if !title.isEmpty { return title }
        if kind == .link, let metadataTitle, !metadataTitle.isEmpty { return metadataTitle }
        if let text { return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces).prefix(120).description }
        if let path { return URL(fileURLWithPath: originalPath ?? path).deletingPathExtension().lastPathComponent }
        return URL(string: originalURL ?? "")?.host ?? L("Link")
    }
    var fileURL: URL? { path.map { URL(fileURLWithPath: $0) } }
    var markupSourceURL: URL? { (markupBasePath ?? path).map { URL(fileURLWithPath: $0) } }
    var recordingOriginalURL: URL? { recordingOriginalPath.map { URL(fileURLWithPath: $0) } }
    var exportFileName: String? { fileURL.map { HistoryFiles.exportName(for: $0, originalPath: originalPath) } }
    var linkURL: URL? { originalURL.flatMap(URL.init(string:)) }
}
struct LibraryCollection: Identifiable, Equatable { let id: UUID; var name: String; var parentID: UUID? }
struct LibraryTag: Identifiable, Equatable { let id: UUID; var name: String }
/// Paged display data; tag labels never become part of the persisted payload.
struct LibraryCardSummary {
    var record: LibraryRecord
    let tagNames: [String]
    let tagCount: Int
    var tagLabel: String {
        let names = tagNames.map { "#" + $0 }.joined(separator: " · ")
        return tagCount > tagNames.count ? names + " · +\(tagCount - tagNames.count)" : names
    }
}
struct LibraryQuery: Equatable {
    enum Scope: Equatable { case saved, favorites, unorganized, recent, shelf, trash, collection(UUID), tag(UUID) }
    enum Sort: String, CaseIterable { case newest, oldest, title, titleDescending, copied, relevance }
    var scope: Scope = .saved
    var kind: LibraryKind?
    var search = ""
    enum SearchMode: String, CaseIterable { case all, text, visual }
    var searchMode: SearchMode = .all
    var visualIDs = [UUID]()
    var favoritesOnly = false
    var tagIDs = Set<UUID>()
    var days: Int?
    var domain = ""
    var sort: Sort = .newest
    var hasFilters: Bool { kind != nil || !search.isEmpty || searchMode != .all || favoritesOnly || !tagIDs.isEmpty || days != nil || !domain.isEmpty }
}

private enum LibrarySQL {
    static func query(_ query: LibraryQuery, limit: Int, offset: Int, now: Date, projection: String = "i.payload", unlimited: Bool = false) -> (String, [SQLValue]) {
        var whereParts = [query.scope == .trash ? "i.deleted IS NOT NULL" : "i.deleted IS NULL"], values = [SQLValue]()
        switch query.scope {
        case .saved: whereParts.append("i.retained IS NOT NULL")
        case .favorites: whereParts.append("i.favorite=1")
        case .unorganized: whereParts += ["i.retained IS NOT NULL", "NOT EXISTS(SELECT 1 FROM item_collections c WHERE c.item=i.id)", "NOT EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id)"]
        case .recent: whereParts.append("i.retained IS NULL")
        case .shelf: whereParts.append("i.shelf=1")
        case .trash: break
        case let .collection(id): whereParts.append("EXISTS(SELECT 1 FROM item_collections c JOIN collections f ON c.collection=f.id WHERE c.item=i.id AND (f.id=? OR f.parent=?))"); values += [.text(id.uuidString), .text(id.uuidString)]
        case let .tag(id): whereParts.append("EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id AND t.tag=?)"); values.append(.text(id.uuidString))
        }
        if let kind = query.kind { whereParts.append("i.kind=?"); values.append(.text(kind.rawValue)) }
        if query.favoritesOnly { whereParts.append("i.favorite=1") }
        for id in query.tagIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            whereParts.append("EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id AND t.tag=?)"); values.append(.text(id.uuidString))
        }
        if let days = query.days { whereParts.append("i.created>=?"); values.append(.real(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)) }
        if !query.domain.isEmpty {
            var domain = query.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            let suffix = "." + domain
            // Literal host boundaries include subdomains without wildcard or
            // suffix collisions (youtube.com must not match notyoutube.com).
            whereParts.append("(i.domain=? OR substr(i.domain,-length(?))=?)")
            values += [.text(domain), .text(suffix), .text(suffix)]
        }
        // Bound literal substring search handles Turkish, short strings, CJK
        // and punctuation. The FTS index also supports future ranked searches.
        var textRank = "0", textRankValues = [SQLValue]()
        if !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var searchParts = [String](), searchValues = [SQLValue]()
            if query.searchMode != .visual {
                for term in query.search.libraryFolded.split(whereSeparator: \.isWhitespace) {
                    searchParts.append("(instr(i.search,?)>0 OR EXISTS(SELECT 1 FROM image_analysis a WHERE a.item=i.id AND a.path=i.path AND instr(a.content,?)>0))")
                    searchValues += [.text(String(term)), .text(String(term))]
                }
            }
            let text = searchParts.isEmpty ? "0" : "(" + searchParts.joined(separator: " AND ") + ")"
            textRank = text; textRankValues = searchValues
            let visual = query.searchMode != .text && !query.visualIDs.isEmpty ? "i.id IN (" + query.visualIDs.map { _ in "?" }.joined(separator: ",") + ")" : "0"
            whereParts.append("(\(text) OR \(visual))"); values += searchValues
            if visual != "0" { values += query.visualIDs.map { .text($0.uuidString) } }
        }
        var order: String
        switch query.sort { case .newest, .relevance: order = "i.created DESC"; case .oldest: order = "i.created ASC"; case .title: order = "i.sort_title ASC"; case .titleDescending: order = "i.sort_title DESC"; case .copied: order = "COALESCE(i.copied,i.created) DESC" }
        if query.sort == .relevance, !query.search.isEmpty, query.searchMode != .text, !query.visualIDs.isEmpty {
            // UUID values are typed, never user SQL. Literal text/OCR matches
            // precede semantic suggestions; semantic images retain model rank.
            let ranks = query.visualIDs.enumerated().map { "WHEN '\($0.element.uuidString)' THEN \($0.offset)" }.joined(separator: " ")
            order = "CASE WHEN \(textRank) THEN -1 ELSE CASE i.id \(ranks) ELSE \(query.visualIDs.count) END END," + order
            values += textRankValues
        }
        let sql = "SELECT \(projection) FROM items i WHERE \(whereParts.joined(separator: " AND ")) ORDER BY \(order),i.rowid DESC"
        return unlimited ? (sql, values) : (sql + " LIMIT ? OFFSET ?", values + [.integer(Int64(max(1, min(limit, 10000)))), .integer(Int64(max(0, offset)))])
    }
    static func decode(_ rows: [[String: SQLValue]]) throws -> [LibraryRecord] {
        try rows.map { row in guard let data = row["payload"]?.data else { throw HistoryFiles.Failure.unsafeFile }; return try JSONDecoder().decode(LibraryRecord.self, from: data) }
    }
}
extension String {
    var libraryFolded: String { folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR")).lowercased() }
}

/// The production source of truth. Existing history classes are adapters to
/// this store; old JSON/preferences are migration input and rollback copies.
@MainActor final class LibraryStore: ObservableObject {
    static let maximumItemNameLength = 160
    enum ItemNameError: Error, LocalizedError {
        case invalid
        var errorDescription: String? { L("Enter a name (1–160 characters)") }
    }
    @Published private(set) var revision = 0
    private(set) var changedKinds = Set(LibraryKind.allCases)
    private(set) var changedIDs = Set<UUID>()
    @Published var notice: String?
    @Published private(set) var searchRevision = 0
    @Published var imageSearchStatus = ""
    var imageSearch: LibraryImageSearch?
    let root: URL
    let databaseURL: URL
    let defaults: UserDefaults
    let files: HistoryFiles
    private let db: LibraryDatabase
    private var textIdentityDataVersion: Int64?
    private let now: () -> Date
    private struct ShelfRemoval {
        let id: UUID
        let removedAt: Date?
    }
    private var shelfRemovalUndo = [[ShelfRemoval]]()
    private struct TrashRemoval {
        let id: UUID
        let onShelf: Bool
        let fingerprint: Data
    }
    private var trashRemovalUndo = [[TrashRemoval]]()
    struct RecordingTrimContext: Equatable, Sendable {
        let token: UUID
        let id: UUID
        let source: URL
        let sourceFingerprint: String
        let snapshot: URL
        let output: URL
    }
    private var recordingTrims = [UUID: RecordingTrimContext]()
    private var recordingTrimPending = Set<String>()
    var canUndoShelfRemoval: Bool { !shelfRemovalUndo.isEmpty }
    var canUndoTrash: Bool { !trashRemovalUndo.isEmpty }
    private let readerQueue = DispatchQueue(label: "local.clipboardline.library.reader", qos: .userInitiated)
    var retentionDays: Int { let days = defaults.integer(forKey: "historyRetentionDays"); return ImageHistory.dayChoices.contains(days) ? days : 30 }
    func retentionDays(for kind: LibraryKind) -> Int { HistoryRetention.days(kind, defaults: defaults) }
    var thumbnailsFolder: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    init(defaults: UserDefaults, inbox: URL, now: @escaping () -> Date = Date.init,
         moveToTrash: @escaping (URL) throws -> URL = HistoryFiles.systemTrash) throws {
        self.defaults = defaults; self.now = now; files = HistoryFiles(inbox: inbox, moveToTrash: moveToTrash)
        root = inbox.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        databaseURL = root.appendingPathComponent("library.sqlite")
        guard root.resolvingSymlinksInPath().path == root.path else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            guard FileManager.default.createFile(atPath: databaseURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw HistoryFiles.Failure.unsafeFile }
        }
        db = try LibraryDatabase(url: databaseURL)
        guard (try db.rows("PRAGMA user_version").first?["user_version"]?.number ?? 0) <= 1 else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=FULL")
        for sql in [
            "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,kind TEXT NOT NULL,created REAL NOT NULL,updated REAL NOT NULL,copied REAL,retained REAL,favorite INTEGER NOT NULL,shelf INTEGER NOT NULL,deleted REAL,path TEXT,normalized TEXT,domain TEXT NOT NULL,sort_title TEXT NOT NULL,search TEXT NOT NULL,payload BLOB NOT NULL)",
            "DROP INDEX IF EXISTS live_image_path", "DROP INDEX IF EXISTS live_link_url",
            "CREATE INDEX IF NOT EXISTS live_image_path ON items(path) WHERE kind='image' AND deleted IS NULL",
            "CREATE INDEX IF NOT EXISTS live_link_url ON items(normalized) WHERE kind='link' AND deleted IS NULL",
            "CREATE INDEX IF NOT EXISTS item_order ON items(deleted,retained,kind,created DESC)",
            "CREATE INDEX IF NOT EXISTS shelf_search_scope ON items(kind,shelf,deleted)",
            "CREATE INDEX IF NOT EXISTS shelf_capture_order ON items(kind,shelf,deleted,created)",
            "CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent TEXT REFERENCES collections(id),folded TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS tags(id TEXT PRIMARY KEY,name TEXT NOT NULL,folded TEXT NOT NULL UNIQUE)",
            "CREATE TABLE IF NOT EXISTS item_collections(item TEXT REFERENCES items(id),collection TEXT REFERENCES collections(id),PRIMARY KEY(item,collection))",
            "CREATE TABLE IF NOT EXISTS item_tags(item TEXT REFERENCES items(id),tag TEXT REFERENCES tags(id),PRIMARY KEY(item,tag))",
            "CREATE INDEX IF NOT EXISTS collection_members ON item_collections(collection,item)",
            "CREATE INDEX IF NOT EXISTS tag_members ON item_tags(tag,item)",
            // Clipboard identity is independent of search folding. Keep the items schema
            // compatible with existing imports and rollback snapshots.
            "CREATE TABLE IF NOT EXISTS text_identity(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,digest BLOB NOT NULL,captured REAL NOT NULL,version INTEGER NOT NULL DEFAULT 1)",
            "CREATE INDEX IF NOT EXISTS text_identity_digest ON text_identity(digest)",
            "CREATE INDEX IF NOT EXISTS text_identity_expiry ON text_identity(captured)",
            // An older rollback app knows nothing about this index. Its text
            // edits must invalidate old digests; startup repairs missing rows.
            "CREATE TRIGGER IF NOT EXISTS text_identity_payload_changed AFTER UPDATE OF payload ON items BEGIN DELETE FROM text_identity WHERE item=NEW.id; END",
            "CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(id UNINDEXED,content,tokenize='unicode61')",
            "CREATE TABLE IF NOT EXISTS image_analysis(item TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,path TEXT NOT NULL,fingerprint TEXT NOT NULL,version TEXT NOT NULL,content TEXT NOT NULL,ocr TEXT NOT NULL,vectors BLOB NOT NULL)",
            // Durable intent also covers a crash between creating a new PNG
            // and committing its record; only unpublished/retired assets go
            // to recoverable Trash, never external source screenshots.
            "CREATE TABLE IF NOT EXISTS image_markup_garbage(path TEXT PRIMARY KEY)"
        ] { try db.execute(sql) }
        if try !db.rows("PRAGMA table_info(text_identity)").contains(where: { $0["name"]?.string == "version" }) {
            try db.execute("ALTER TABLE text_identity ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
        }
        try migrateLegacy()
        try backfillTextIdentity()
        try db.execute("PRAGMA user_version=1")
        drainMarkupGarbage()
    }
    private func migrateLegacy() throws {
        guard try db.rows("SELECT value FROM metadata WHERE key='migration-v1'").isEmpty else { return }
        // Decode before writing any record or applying expiry. A damaged
        // source is preserved and blocks activation rather than becoming empty.
        let images: [ImageHistory.Entry]
        if let data = defaults.data(forKey: "imageHistoryV1") { images = try JSONDecoder().decode([ImageHistory.Entry].self, from: data) }
        else { images = ImageHistory(defaults: defaults, inbox: files.inbox, now: now, moveToTrash: files.moveToTrash, pruneOnLoad: false).entries }
        let textFile = files.inbox.appendingPathComponent("Texts/history.json")
        var texts = [TextHistory.Entry]()
        if FileManager.default.fileExists(atPath: textFile.path) {
            guard textFile.resolvingSymlinksInPath().path == textFile.standardizedFileURL.path,
                  (try textFile.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 32 * 1024 * 1024 else { throw HistoryFiles.Failure.unsafeFile }
            texts = try JSONDecoder().decode([TextHistory.Entry].self, from: Data(contentsOf: textFile))
        }
        let backup = root.appendingPathComponent("Backups/Before-Library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(try PropertyListSerialization.data(fromPropertyList: defaults.dictionaryRepresentation(), format: .binary, options: 0), to: backup.appendingPathComponent("preferences.plist"))
        if FileManager.default.fileExists(atPath: textFile.path) { try FileManager.default.copyItem(at: textFile, to: backup.appendingPathComponent("text-history.json")) }
        let owned = files.files(in: files.inbox, matching: files.isClipboardCopy) + files.files(in: files.favoritesFolder, matching: files.isFavoriteCopy)
        for url in owned { try FileManager.default.copyItem(at: url, to: backup.appendingPathComponent(url.lastPathComponent)) }
        try db.transaction {
            var paths = Set<String>(), textIDs = Set<UUID>()
            for entry in images.reversed() where paths.insert(entry.path).inserted {
                var item = LibraryRecord(id: entry.id, kind: .image, createdAt: entry.capturedAt, updatedAt: entry.capturedAt)
                item.path = entry.path; item.originalPath = entry.originalPath; item.favorite = entry.pinned; item.title = entry.title ?? ""
                if entry.pinned { item.retainedAt = entry.capturedAt; try ensureOwned(&item) }
                try put(item)
            }
            for entry in texts.reversed() where textIDs.insert(entry.id).inserted {
                guard entry.text.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
                var item = LibraryRecord(id: entry.id, kind: .text, createdAt: entry.capturedAt, updatedAt: entry.capturedAt)
                item.text = entry.text; item.favorite = entry.pinned; item.retainedAt = entry.pinned ? entry.capturedAt : nil; item.title = entry.title ?? ""
                try put(item)
            }
            let count = try db.rows("SELECT count(*) AS n FROM items").first?["n"]?.number
            guard count == Int64(paths.count + textIDs.count) else { throw HistoryFiles.Failure.unsafeFile }
            try db.execute("INSERT INTO metadata VALUES('migration-v1',?)", [.text(backup.path)])
        }
        try db.backup(to: backup.appendingPathComponent("library-after-migration.sqlite"))
    }
    private static func textDigest(_ text: String) -> Data { Data(SHA256.hash(data: Data(TextIdentity.key(text).utf8))) }
    private func putTextIdentity(_ item: LibraryRecord) throws {
        if item.kind == .text, let text = item.text {
            try db.execute("INSERT INTO text_identity(item,digest,captured,version) VALUES(?,?,?,?) ON CONFLICT(item) DO UPDATE SET digest=excluded.digest,captured=excluded.captured,version=excluded.version", [.text(item.id.uuidString), .blob(Self.textDigest(text)), .real((item.lastCapturedAt ?? item.createdAt).timeIntervalSince1970), .integer(TextIdentity.version)])
        } else {
            try db.execute("DELETE FROM text_identity WHERE item=?", [.text(item.id.uuidString)])
        }
    }
    /// Existing libraries need only a derived identity index, not a destructive
    /// cleanup. Read a bounded page of missing IDs, then one payload at a
    /// time; a large text archive must not all be decoded into memory at
    /// launch. Usually no rows are missing after the initial backfill, but
    /// this also repairs inserts and edits made by an older rollback app.
    private func backfillTextIdentity() throws {
        let observedVersion = try db.transaction {
            let observed = try db.rows("PRAGMA data_version").first?["data_version"]?.number
            try repairTextIdentity()
            return observed
        }
        textIdentityDataVersion = observedVersion
    }
    private func repairTextIdentity() throws {
        var cursor = ""
        while true {
            let rows = try db.rows("SELECT i.id FROM items i LEFT JOIN text_identity t ON t.item=i.id WHERE i.kind='text' AND (t.item IS NULL OR t.version<>?) AND i.id>? ORDER BY i.id LIMIT 256", [.integer(TextIdentity.version), .text(cursor)])
            guard !rows.isEmpty else { break }
            for row in rows {
                guard let key = row["id"]?.string, let id = UUID(uuidString: key), let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
                try putTextIdentity(value)
                cursor = key
            }
        }
        try db.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('text-identity-v2','complete')")
    }
    private func put(_ item: LibraryRecord) throws {
        let tagNames = try tags(for: item.id).map(\.name).joined(separator: " ")
        // A personal label supplements the recognizable source filename.
        // Index its basename only; private directory names are not content.
        let imageName = item.kind == .image ? (item.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.fileURL?.lastPathComponent ?? "") : ""
        let content = [item.displayTitle,imageName,item.metadataTitle ?? "",item.text ?? "",item.note,item.originalURL ?? "",item.uploadedURL ?? "",tagNames].joined(separator: " ").libraryFolded
        try db.execute("INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,created=excluded.created,updated=excluded.updated,copied=excluded.copied,retained=excluded.retained,favorite=excluded.favorite,shelf=excluded.shelf,deleted=excluded.deleted,path=excluded.path,normalized=excluded.normalized,domain=excluded.domain,sort_title=excluded.sort_title,search=excluded.search,payload=excluded.payload", [
            .text(item.id.uuidString), .text(item.kind.rawValue), .real(item.createdAt.timeIntervalSince1970), .real(item.updatedAt.timeIntervalSince1970),
            item.lastCopiedAt.map { .real($0.timeIntervalSince1970) } ?? .null, item.retainedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .integer(item.favorite ? 1 : 0), .integer(item.onShelf ? 1 : 0), item.deletedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            item.path.map(SQLValue.text) ?? .null, item.normalizedURL.map(SQLValue.text) ?? .null, .text(item.linkURL?.host?.lowercased() ?? ""),
            .text(item.displayTitle.libraryFolded), .text(content), .blob(try JSONEncoder().encode(item))])
        try putTextIdentity(item)
        try db.execute("DELETE FROM search_fts WHERE id=?", [.text(item.id.uuidString)])
        try db.execute("INSERT INTO search_fts(id,content) VALUES(?,?)", [.text(item.id.uuidString), .text(content)])
    }
    func item(_ id: UUID) throws -> LibraryRecord? { try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE id=?", [.text(id.uuidString)])).first }
    /// Read cached OCR only for the current live image and unchanged pixels.
    /// File metadata and SQLite reads stay on the reader queue; no search
    /// model, index scan or image decode is started by this clipboard action.
    func imageTextSource(_ id: UUID) async throws -> ImageTextSource? {
        let databaseURL = self.databaseURL
        return try await withCheckedThrowingContinuation { continuation in
            readerQueue.async {
                do {
                    let connection = try LibraryDatabase(url: databaseURL, readOnly: true, verify: false)
                    let rows = try connection.rows("SELECT i.path,a.path AS analysis_path,a.fingerprint,a.version,a.ocr FROM items i LEFT JOIN image_analysis a ON a.item=i.id WHERE i.id=? AND i.kind='image' AND i.deleted IS NULL", [.text(id.uuidString)])
                    guard let row = rows.first, let path = row["path"]?.string else {
                        continuation.resume(returning: nil); return
                    }
                    let url = URL(fileURLWithPath: path)
                    guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"].contains(url.pathExtension.lowercased()),
                          let fingerprint = ImageSearchWorker.fingerprint(url) else {
                        continuation.resume(returning: nil); return
                    }
                    let version = row["version"]?.string
                    let fresh = row["analysis_path"]?.string == path && row["fingerprint"]?.string == fingerprint &&
                        (version == "vision-ocr-v1" || version == ImageSearchWorker.version)
                    continuation.resume(returning: ImageTextSource(url: url, fingerprint: fingerprint, cachedText: fresh ? row["ocr"]?.string : nil))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func shelfItems(_ kind: LibraryKind) throws -> [LibraryRecord] {
        let order = kind == .link ? "COALESCE(copied,created) DESC,rowid DESC" : "created DESC,rowid DESC"
        return try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE kind=? AND shelf=1 AND deleted IS NULL ORDER BY \(order)", [.text(kind.rawValue)]))
    }
    func query(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0) throws -> [LibraryRecord] {
        let (sql, values) = LibrarySQL.query(query, limit: limit, offset: offset, now: now()); return try LibrarySQL.decode(db.rows(sql, values))
    }
    func queryAsync(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0, completion: @escaping (Result<[LibraryRecord], Error>) -> Void) {
        let url = databaseURL, date = now()
        readerQueue.async {
            let result = Result { () throws -> [LibraryRecord] in
                let db = try LibraryDatabase(url: url, readOnly: true, verify: false)
                let (sql, values) = LibrarySQL.query(query, limit: limit, offset: offset, now: date)
                return try LibrarySQL.decode(db.rows(sql, values))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func cardSummariesAsync(_ query: LibraryQuery, limit: Int = 80, offset: Int = 0, completion: @escaping (Result<[LibraryCardSummary], Error>) -> Void) {
        let url = databaseURL, date = now()
        readerQueue.async {
            let result = Result { () throws -> [LibraryCardSummary] in
                let connection = try LibraryDatabase(url: url, readOnly: true, verify: false)
                // One read statement gives each page a consistent record/tag
                // snapshot, without per-card database reads on the UI thread.
                let tags = "FROM item_tags it JOIN tags t ON t.id=it.tag WHERE it.item=i.id ORDER BY t.folded,t.id"
                let projection = "i.payload,(SELECT t.name \(tags) LIMIT 1) AS tag0,(SELECT t.name \(tags) LIMIT 1 OFFSET 1) AS tag1,(SELECT count(*) FROM item_tags it WHERE it.item=i.id) AS tag_count"
                let (sql, values) = LibrarySQL.query(query, limit: min(limit, 80), offset: offset, now: date, projection: projection)
                let rows = try connection.rows(sql, values), records = try LibrarySQL.decode(rows)
                return zip(records, rows).map { record, row in
                    LibraryCardSummary(record: record, tagNames: [row["tag0"]?.string, row["tag1"]?.string].compactMap { $0 }, tagCount: Int(row["tag_count"]?.number ?? 0))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func queryIDs(_ query: LibraryQuery) throws -> [UUID] {
        let (sql, values) = LibrarySQL.query(query, limit: 1, offset: 0, now: now(), projection: "i.id", unlimited: true)
        return try db.rows(sql, values).compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
    }
    func queryIDsAsync(_ query: LibraryQuery, completion: @escaping (Result<[UUID], Error>) -> Void) {
        let url = databaseURL, date = now()
        readerQueue.async {
            let result = Result { () throws -> [UUID] in
                let connection = try LibraryDatabase(url: url, readOnly: true, verify: false)
                let (sql, values) = LibrarySQL.query(query, limit: 1, offset: 0, now: date, projection: "i.id", unlimited: true)
                return try connection.rows(sql, values).compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    /// Shelf search shares the persisted, folded metadata/OCR index with the
    /// Library, but includes both temporary and saved records still on a row.
    /// It deliberately skips semantic suggestions: typing in a narrow shelf
    /// needs literal matches, without starting an image/model scan per key.
    func shelfMatchingIDsAsync(kind: LibraryKind, search: String, favoritesOnly: Bool = false,
                               completion: @escaping (Result<[UUID], Error>) -> Void) {
        var query = LibraryQuery(scope: .shelf, kind: kind, search: search)
        query.searchMode = .text; query.favoritesOnly = favoritesOnly
        queryIDsAsync(query, completion: completion)
    }
    func records(_ ids: [UUID]) throws -> [LibraryRecord] { try ids.map { guard let record = try item($0) else { throw HistoryFiles.Failure.unsafeFile }; return record } }
    func resolveImageSearch(_ query: LibraryQuery, completion: @escaping (LibraryQuery) -> Void) {
        guard let imageSearch else { var query = query; query.visualIDs = []; completion(query); return }
        imageSearch.resolve(query, completion: completion)
    }
    func imageSearchChanged() { searchRevision += 1 }
    @discardableResult func createNote() throws -> LibraryRecord {
        let date = now(); var record = LibraryRecord(id: UUID(), kind: .text, createdAt: date, updatedAt: date)
        record.text = ""; record.retainedAt = date; record.title = L("Untitled note")
        try db.transaction { try put(record) }; changed(); return record
    }
    @discardableResult func captureImage(_ url: URL, capturedAt: Date? = nil) throws -> LibraryRecord {
        if let existing = try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE path=? AND deleted IS NULL", [.text(url.standardizedFileURL.path)])).first { return existing }
        guard files.isRegularFile(url) else { throw HistoryFiles.Failure.unsafeFile }
        let date = capturedAt ?? now(); var item = LibraryRecord(id: UUID(), kind: .image, createdAt: date, updatedAt: date); item.path = url.standardizedFileURL.path; item.captureRevision = UUID()
        try db.transaction { try put(item) }; changed([item.id]); return item
    }
    @discardableResult func captureText(_ text: String) throws -> LibraryRecord? {
        guard !text.isEmpty, text.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
        let date = now()
        var affected = [UUID]()
        var textFileRollback: (url: URL, data: Data)?
        var observedVersion: Int64?
        let captured: LibraryRecord
        do { captured = try db.transaction { () throws -> LibraryRecord in
            observedVersion = try db.rows("PRAGMA data_version").first?["data_version"]?.number
            // A rollback app can insert or edit while this app stays open.
            // Repair only after another connection writes, not on every copy.
            if observedVersion != textIdentityDataVersion { try repairTextIdentity() }
            let identity = TextIdentity.key(text)
            // The index narrows the read; verify the normalized candidate too.
            let rows = try db.rows("SELECT i.id FROM text_identity t JOIN items i ON i.id=t.item WHERE t.digest=? AND i.kind='text' AND i.deleted IS NULL ORDER BY i.created DESC,i.rowid DESC", [.blob(Self.textDigest(text))])
            var canonical: LibraryRecord?
            for row in rows {
                guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), var duplicate = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
                guard let candidate = duplicate.text, TextIdentity.key(candidate).utf8.elementsEqual(identity.utf8) else { continue }
                guard var current = canonical else { canonical = duplicate; continue }
                // Preserve personal organization on the surviving identity.
                // The old row and its memberships remain recoverable in Trash.
                current.favorite = current.favorite || duplicate.favorite
                if let retained = duplicate.retainedAt { current.retainedAt = current.retainedAt.map { min($0, retained) } ?? retained }
                if current.title.isEmpty, !duplicate.title.isEmpty { current.title = duplicate.title }
                if current.note.isEmpty, !duplicate.note.isEmpty { current.note = duplicate.note }
                if current.uploadedURL == nil, let url = duplicate.uploadedURL { current.uploadedURL = url; current.uploadedAt = duplicate.uploadedAt }
                try db.execute("INSERT OR IGNORE INTO item_collections(item,collection) SELECT ?,collection FROM item_collections WHERE item=?", [.text(current.id.uuidString), .text(id.uuidString)])
                try db.execute("INSERT OR IGNORE INTO item_tags(item,tag) SELECT ?,tag FROM item_tags WHERE item=?", [.text(current.id.uuidString), .text(id.uuidString)])
                duplicate.deletedAt = date; duplicate.onShelf = false; duplicate.updatedAt = date; duplicate.trashRevision = UUID()
                try put(duplicate)
                affected.append(id)
                canonical = current
            }
            var result = canonical ?? LibraryRecord(id: UUID(), kind: .text, createdAt: date, updatedAt: date)
            if let canonical {
                textFileRollback = try rewriteMaterializedText(canonical, to: text)
                if Data((canonical.text ?? "").utf8) != Data(text.utf8) {
                    result.uploadedURL = nil; result.uploadedAt = nil
                }
            }
            var orderedDate = date
            if case let .real(front)? = try db.rows("SELECT created FROM items WHERE kind='text' AND shelf=1 AND deleted IS NULL ORDER BY created DESC,rowid DESC LIMIT 1").first?["created"] {
                // Reusing a stable ID also reuses its rowid. An equal clock
                // reading must still move that record ahead of a newer row;
                // subsequent new captures must also stay ahead of this tiny
                // ordering increment or a clock that has moved backwards.
                let timestamp = date.timeIntervalSince1970
                if timestamp < front || (canonical != nil && timestamp == front) {
                    orderedDate = Date(timeIntervalSince1970: front.nextUp)
                }
            }
            result.text = text; result.createdAt = orderedDate; result.updatedAt = date
            result.lastCapturedAt = date; result.lastCopiedAt = date; result.onShelf = true
            result.captureRevision = UUID()
            try put(result)
            affected.append(result.id)
            return result
        } } catch {
            if let rollback = textFileRollback { try? writePrivate(rollback.data, to: rollback.url) }
            throw error
        }
        // Cache the version seen under the transaction's writer lock. A later
        // writer must remain observable on the next capture, including on error.
        textIdentityDataVersion = observedVersion
        invalidateShelfUndo(affected)
        invalidateTrashUndo(affected)
        changed(affected)
        return captured
    }
    @discardableResult func captureLink(_ url: URL) throws -> LibraryRecord {
        guard let normalized = LinkIdentity.normalized(url) else { throw HistoryFiles.Failure.unsafeFile }
        if var item = try LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE normalized=? AND deleted IS NULL ORDER BY created DESC,rowid DESC LIMIT 1", [.text(normalized)])).first {
            item.onShelf = true; item.updatedAt = now(); item.lastCopiedAt = now(); item.lastCapturedAt = now(); item.captureRevision = UUID()
            try db.transaction { try put(item) }; changed([item.id]); return item
        }
        let date = now(); var item = LibraryRecord(id: UUID(), kind: .link, createdAt: date, updatedAt: date)
        item.originalURL = url.absoluteString; item.normalizedURL = normalized; item.lastCapturedAt = date; item.captureRevision = UUID()
        try db.transaction { try put(item) }; changed([item.id]); return item
    }
    private func ensureOwned(_ item: inout LibraryRecord) throws {
        guard item.kind == .image, let url = item.fileURL, !files.isAppCopy(url) else { return }
        let copy = try files.makeFavoriteCopy(of: url); item.originalPath = item.originalPath ?? url.path; item.path = copy.path
    }
    /// Save editable vectors and a flattened PNG under the same item identity.
    /// Nothing writes to the original screenshot. A failed render/write/SQLite
    /// transaction leaves the prior record and its visible pixels unchanged.
    @discardableResult func saveImageMarkup(_ id: UUID, document: ImageMarkupDocument) throws -> LibraryRecord {
        let document = try document.validated()
        guard var value = try item(id), value.kind == .image, value.deletedAt == nil,
              let source = value.markupSourceURL, files.isRegularFile(source) else { throw HistoryFiles.Failure.unsafeFile }
        let previous = value
        if (document == value.imageMarkup && value.fileURL.map(files.isRegularFile) == true) ||
            (document.isEmpty && value.imageMarkup == nil && value.markupBasePath == nil) { return value }
        var pending = [URL]()
        do {
            var base = source
            if !document.isEmpty, value.markupBasePath == nil, !files.isAppCopy(source) {
                base = try reserveMarkupAsset(extension: source.pathExtension)
                pending.append(base)
                try FileManager.default.copyItem(at: source, to: base)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: base.path)
                guard files.isFavoriteCopy(base) else { throw HistoryFiles.Failure.unsafeFile }
                let handle = try FileHandle(forWritingTo: base)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            if document.isEmpty {
                value.path = base.path; value.imageMarkup = nil; value.markupBasePath = nil
            } else {
                let data = try ImageMarkupRenderer.render(sourceURL: base, document: document)
                let rendered = try reserveMarkupAsset(extension: "png")
                pending.append(rendered)
                try writeNewMarkupAsset(data, to: rendered)
                value.originalPath = value.originalPath ?? source.path
                value.path = rendered.path; value.markupBasePath = base.path; value.imageMarkup = document
            }
            value.uploadedURL = nil; value.uploadedAt = nil
            value.updatedAt = now()
            try db.transaction {
                try put(value)
                // Old OCR cannot describe the new pixels, including when all
                // marks are removed and the base image is restored.
                try db.execute("DELETE FROM image_analysis WHERE item=?", [.text(id.uuidString)])
                for asset in pending { try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(asset.path)]) }
                if previous.markupBasePath != nil, let old = previous.fileURL,
                   old.path != value.path, old.path != value.markupBasePath, files.isFavoriteCopy(old) {
                    try db.execute("INSERT OR IGNORE INTO image_markup_garbage VALUES(?)", [.text(old.path)])
                }
            }
        } catch {
            // A durable queue entry was recorded before every creation. This
            // retries safely after an interrupted save or failed Trash action.
            drainMarkupGarbage()
            throw error
        }
        drainMarkupGarbage()
        changed([id]); return value
    }
    private func reserveMarkupAsset(extension ext: String) throws -> URL {
        try reserveManagedAsset(extension: ext, allowed: ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"])
    }
    private func reserveManagedAsset(extension ext: String, allowed: Set<String>) throws -> URL {
        guard allowed.contains(ext.lowercased()),
              files.favoritesFolder.resolvingSymlinksInPath().path == files.favoritesFolder.path else { throw HistoryFiles.Failure.unsafeFile }
        try FileManager.default.createDirectory(at: files.favoritesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.favoritesFolder.path)
        let result = files.favoritesFolder.appendingPathComponent("Favorite \(UUID()).\(ext.lowercased())")
        guard !FileManager.default.fileExists(atPath: result.path) else { throw HistoryFiles.Failure.unsafeFile }
        try db.execute("INSERT INTO image_markup_garbage VALUES(?)", [.text(result.path)])
        return result
    }
    private func writeNewMarkupAsset(_ data: Data, to url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) } ?? -1 }
        guard descriptor >= 0 else { throw HistoryFiles.Failure.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard files.isFavoriteCopy(url) else { throw HistoryFiles.Failure.unsafeFile }
    }
    private func drainMarkupGarbage() {
        guard let queued = try? db.rows("SELECT path FROM image_markup_garbage"), !queued.isEmpty,
              let records = try? LibrarySQL.decode(db.rows("SELECT payload FROM items WHERE kind='image'")) else { return }
        let referenced = Set(records.flatMap { [$0.path, $0.markupBasePath, $0.recordingOriginalPath].compactMap { $0 } }).union(recordingTrimPending)
        for row in queued {
            guard let path = row["path"]?.string else { continue }
            if referenced.contains(path) { continue }
            let url = URL(fileURLWithPath: path)
            do {
                if FileManager.default.fileExists(atPath: path) {
                    guard files.isFavoriteCopy(url) else { continue }
                    _ = try files.trashAppCopy(url)
                }
                try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(path)])
            } catch { /* Retry on the next save or launch; no permanent deletion. */ }
        }
    }
    /// Snapshot outside the main actor so a large recording never freezes the
    /// shelves. A durable unpublished-asset intent covers interruption/crash.
    func prepareRecordingTrim(_ id: UUID) async throws -> RecordingTrimContext {
        guard let value = try item(id), value.kind == .image, value.deletedAt == nil,
              let source = value.fileURL, isRecordingFile(source), files.isRegularFile(source),
              value.recordingOriginalURL.map(files.isFavoriteCopy) != false else { throw HistoryFiles.Failure.unsafeFile }
        var reserved = [URL]()
        do {
            let snapshot = try reserveManagedAsset(extension: source.pathExtension, allowed: ["mov", "mp4"]); reserved.append(snapshot)
            let output = try reserveManagedAsset(extension: source.pathExtension, allowed: ["mov", "mp4"]); reserved.append(output)
            recordingTrimPending.formUnion(reserved.map(\.path))
            let worker = Task.detached(priority: .userInitiated) { try RecordingTrimFiles.snapshot(source, to: snapshot) }
            let fingerprint = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard let current = try item(id), current.deletedAt == nil, current.path == source.path else { throw HistoryFiles.Failure.unsafeFile }
            let context = RecordingTrimContext(token: UUID(), id: id, source: source, sourceFingerprint: fingerprint, snapshot: snapshot, output: output)
            recordingTrims[context.token] = context
            return context
        } catch {
            recordingTrimPending.subtract(reserved.map(\.path)); drainMarkupGarbage(); throw error
        }
    }
    func discardRecordingTrim(_ context: RecordingTrimContext) {
        guard recordingTrims[context.token] == context else { return }
        recordingTrims.removeValue(forKey: context.token)
        recordingTrimPending.subtract([context.snapshot.path, context.output.path])
        drainMarkupGarbage()
    }
    /// Publish the validated derivative under the existing ID only. Pinning,
    /// retention, names, notes and memberships may change while export runs;
    /// take them from the current record rather than its opening snapshot.
    @discardableResult func commitRecordingTrim(_ context: RecordingTrimContext) async throws -> LibraryRecord {
        guard recordingTrims[context.token] == context else { throw HistoryFiles.Failure.unsafeFile }
        defer { discardRecordingTrim(context) }
        let worker = Task.detached(priority: .userInitiated) {
            try await RecordingTrimFiles.validateExport(context.output)
            guard try RecordingTrimFiles.fingerprint(context.source) == context.sourceFingerprint else { throw HistoryFiles.Failure.unsafeFile }
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard recordingTrims[context.token] == context,
              var value = try item(context.id), value.kind == .image, value.deletedAt == nil, value.path == context.source.path,
              files.isFavoriteCopy(context.snapshot), files.isFavoriteCopy(context.output),
              value.recordingOriginalURL.map(files.isFavoriteCopy) != false else { throw HistoryFiles.Failure.unsafeFile }
        let previousPath = value.path
        value.recordingOriginalPath = value.recordingOriginalPath ?? context.snapshot.path
        value.originalPath = value.originalPath ?? context.source.path
        value.uploadedURL = nil; value.uploadedAt = nil
        value.path = context.output.path; value.updatedAt = now()
        try db.transaction {
            try put(value)
            try db.execute("DELETE FROM image_analysis WHERE item=?", [.text(value.id.uuidString)])
            for path in [value.path, value.recordingOriginalPath].compactMap({ $0 }) {
                try db.execute("DELETE FROM image_markup_garbage WHERE path=?", [.text(path)])
            }
            if let path = previousPath, path != value.recordingOriginalPath, files.isFavoriteCopy(URL(fileURLWithPath: path)) {
                try db.execute("INSERT OR IGNORE INTO image_markup_garbage VALUES(?)", [.text(path)])
            }
        }
        changed([value.id]); return value
    }
    func update(_ id: UUID, _ transform: (inout LibraryRecord) throws -> Void) throws {
        guard var value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }
        let previous = value
        try transform(&value); value.updatedAt = now()
        if value.kind == .text, Data((previous.text ?? "").utf8) != Data((value.text ?? "").utf8) {
            value.uploadedURL = nil; value.uploadedAt = nil
        }
        if previous.deletedAt == nil, value.deletedAt != nil { value.trashRevision = UUID() }
        else if previous.deletedAt != nil, value.deletedAt == nil { value.trashRevision = nil }
        if value.retainedAt != nil { try ensureOwned(&value) }
        guard (value.text?.utf8.count ?? 0) <= TextClipboardWatcher.maximumDataBytes, value.note.utf8.count <= TextClipboardWatcher.maximumDataBytes else { throw HistoryFiles.Failure.unsafeFile }
        let textFileRollback = value.kind == .text ? try rewriteMaterializedText(previous, to: value.text ?? "") : nil
        do { try db.transaction { try put(value) } }
        catch { if let rollback = textFileRollback { try? writePrivate(rollback.data, to: rollback.url) }; throw error }
        changed([id])
    }
    private func rewriteMaterializedText(_ previous: LibraryRecord, to text: String) throws -> (url: URL, data: Data)? {
        let old = Data((previous.text ?? "").utf8), new = Data(text.utf8)
        guard old != new else { return nil }
        let file = files.inbox.appendingPathComponent("Texts/Text \(previous.id).txt")
        let isLink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard FileManager.default.fileExists(atPath: file.path) || isLink else { return nil }
        guard files.isRegularFile(file), file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
              try Data(contentsOf: file) == old else { throw HistoryFiles.Failure.unsafeFile }
        try writePrivate(new, to: file)
        return (file, old)
    }
    func retain(_ ids: [UUID]) throws { try mutate(ids) { if $0.retainedAt == nil { $0.retainedAt = self.now() } } }
    /// Naming is one durable action: never publish a title without its pin or
    /// pin an external screenshot without first protecting a private copy.
    /// Clipboard bytes, fetched metadata and organization stay independent.
    @discardableResult func nameAndPin(_ id: UUID, name: String) throws -> LibraryRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLineOrControl = name.unicodeScalars.contains {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
        guard !name.isEmpty, name.count <= Self.maximumItemNameLength,
              name.utf8.count <= 1024, !hasLineOrControl else { throw ItemNameError.invalid }
        guard var value = try item(id), value.deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }
        let previousPath = value.path
        value.title = name; value.favorite = true
        value.retainedAt = value.retainedAt ?? now(); value.updatedAt = now()
        try ensureOwned(&value)
        do { try db.transaction { try put(value) } }
        catch {
            if value.path != previousPath, let copy = value.fileURL, files.isFavoriteCopy(copy) { _ = try? files.trashAppCopy(copy) }
            throw error
        }
        changed([id]); return value
    }
    func toggleFavorite(_ ids: [UUID]) throws { try mutate(ids) { $0.favorite.toggle(); if $0.favorite && $0.retainedAt == nil { $0.retainedAt = self.now() } } }
    private func mutate(_ ids: [UUID], _ transform: (inout LibraryRecord) throws -> Void) throws {
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        for index in values.indices { try transform(&values[index]); values[index].updatedAt = now(); if values[index].retainedAt != nil { try ensureOwned(&values[index]) } }
        try db.transaction { for value in values { try put(value) } }
        invalidateTrashUndo(ids); changed(ids)
    }
    func removeFromShelf(_ ids: [UUID]) throws {
        let values = try records(Array(Set(ids))).filter { $0.onShelf && $0.deletedAt == nil }
        guard !values.isEmpty else { return }
        let date = now()
        try mutate(values.map(\.id)) { $0.onShelf = false; if $0.retainedAt == nil { $0.deletedAt = date; $0.trashRevision = UUID() } }
        shelfRemovalUndo.append(values.map { ShelfRemoval(id: $0.id, removedAt: $0.retainedAt == nil ? date : nil) })
        if shelfRemovalUndo.count > 32 { shelfRemovalUndo.removeFirst() }
    }
    /// Restore only shelf visibility/deletion flags. Edits, pins, tags, folders,
    /// original dates and managed file paths may have changed since removal.
    @discardableResult func undoShelfRemoval() throws -> [UUID] {
        while let snapshot = shelfRemovalUndo.last {
            let values = try snapshot.filter { entry in
                guard let record = try item(entry.id) else { return false }
                return !record.onShelf && record.deletedAt == entry.removedAt
            }
            guard !values.isEmpty else { shelfRemovalUndo.removeLast(); continue }
            let ids = values.map(\.id)
            try mutate(ids) { $0.onShelf = true; $0.deletedAt = nil; $0.trashRevision = nil }
            shelfRemovalUndo.removeLast(); return ids
        }
        return []
    }
    private func invalidateShelfUndo(_ ids: [UUID]) {
        let affected = Set(ids)
        shelfRemovalUndo = shelfRemovalUndo.map { $0.filter { !affected.contains($0.id) } }.filter { !$0.isEmpty }
    }
    func trash(_ ids: [UUID]) throws { try mutate(ids) { $0.deletedAt = self.now(); $0.onShelf = false; $0.trashRevision = UUID() }; invalidateShelfUndo(ids) }
    /// Library user actions have a separate, bounded undo history. Keep only
    /// visibility and a digest of the exact committed trash generation; never
    /// retain a second megabyte-sized text or a copy of image bytes in RAM.
    func trashUndoably(_ ids: [UUID]) throws {
        var snapshot = [TrashRemoval]()
        try db.transaction {
            let date = now()
            var seen = Set<UUID>(), previousVisibility = [(UUID, Bool)]()
            for id in ids where seen.insert(id).inserted {
                guard var value = try item(id), value.deletedAt == nil else { continue }
                let onShelf = value.onShelf
                value.deletedAt = date; value.onShelf = false; value.updatedAt = date; value.trashRevision = UUID()
                try put(value)
                previousVisibility.append((id, onShelf))
            }
            for (id, onShelf) in previousVisibility {
                guard let fingerprint = try trashFingerprint(id) else { throw HistoryFiles.Failure.unsafeFile }
                snapshot.append(TrashRemoval(id: id, onShelf: onShelf, fingerprint: fingerprint))
            }
        }
        guard !snapshot.isEmpty else { return }
        let affected = snapshot.map(\.id)
        invalidateShelfUndo(affected); invalidateTrashUndo(affected)
        trashRemovalUndo.append(snapshot)
        if trashRemovalUndo.count > 80 { trashRemovalUndo.removeFirst(trashRemovalUndo.count - 80) }
        changed(affected)
    }
    /// Restore flags only when the complete committed row and organization
    /// still match. Later captures, edits, restores and re-trashes are never
    /// overwritten, including writers using the same clock and another store.
    @discardableResult func undoTrash() throws -> [UUID] {
        guard !trashRemovalUndo.isEmpty else { return [] }
        var consumed = 0, restored = [UUID]()
        try db.transaction {
            for snapshot in trashRemovalUndo.reversed() {
                consumed += 1
                let eligible = try snapshot.filter { entry in try trashFingerprint(entry.id) == entry.fingerprint }
                guard !eligible.isEmpty else { continue }
                let date = now()
                for entry in eligible {
                    guard var value = try item(entry.id), value.deletedAt != nil else { throw HistoryFiles.Failure.unsafeFile }
                    value.deletedAt = nil; value.onShelf = entry.onShelf; value.updatedAt = date; value.trashRevision = nil
                    try put(value); restored.append(entry.id)
                }
                break
            }
        }
        // Transaction failures leave both the data and every pending batch
        // intact. Even stale batches are retired only after a successful commit.
        trashRemovalUndo.removeLast(consumed)
        if !restored.isEmpty { invalidateShelfUndo(restored) }
        if consumed > 0 { changed(restored) }
        return restored
    }
    private func invalidateTrashUndo(_ ids: [UUID]) {
        let affected = Set(ids)
        trashRemovalUndo = trashRemovalUndo.map { $0.filter { !affected.contains($0.id) } }.filter { !$0.isEmpty }
    }
    private func trashFingerprint(_ id: UUID) throws -> Data? {
        guard let row = try db.rows("SELECT * FROM items WHERE id=? AND deleted IS NOT NULL", [.text(id.uuidString)]).first else { return nil }
        var digest = SHA256()
        func field(_ value: Data) {
            var size = UInt64(value.count).bigEndian
            digest.update(data: withUnsafeBytes(of: &size) { Data($0) }); digest.update(data: value)
        }
        func value(_ value: SQLValue) {
            switch value {
            case let .text(text): field(Data("text".utf8)); field(Data(text.utf8))
            case let .integer(number): field(Data("integer".utf8)); field(Data(String(number).utf8))
            case let .real(number): field(Data("real".utf8)); field(Data(String(number.bitPattern, radix: 16).utf8))
            case let .blob(data): field(Data("blob".utf8)); field(data)
            case .null: field(Data("null".utf8))
            }
        }
        for key in row.keys.sorted() { field(Data(key.utf8)); value(row[key]!) }
        let folders = try db.rows("SELECT c.id,c.name,c.parent FROM collections c JOIN item_collections m ON m.collection=c.id WHERE m.item=? ORDER BY c.id", [.text(id.uuidString)])
        let tags = try db.rows("SELECT t.id,t.name FROM tags t JOIN item_tags m ON m.tag=t.id WHERE m.item=? ORDER BY t.id", [.text(id.uuidString)])
        for (kind, rows) in [("folders", folders), ("tags", tags)] {
            field(Data(kind.utf8))
            for row in rows { for key in row.keys.sorted() { field(Data(key.utf8)); value(row[key]!) } }
        }
        return Data(digest.finalize())
    }
    private static let unsavedHistoryWhere = "i.deleted IS NULL AND i.retained IS NULL AND i.favorite=0 AND NOT EXISTS(SELECT 1 FROM item_collections c WHERE c.item=i.id) AND NOT EXISTS(SELECT 1 FROM item_tags t WHERE t.item=i.id)"
    func unsavedHistoryCount(kind: LibraryKind? = nil) throws -> Int {
        let clause = Self.unsavedHistoryWhere + (kind == nil ? "" : " AND i.kind=?")
        let values: [SQLValue] = kind.map { [.text($0.rawValue)] } ?? []
        return Int(try db.rows("SELECT COUNT(*) AS n FROM items i WHERE " + clause, values).first?["n"]?.number ?? 0)
    }
    func unsavedHistorySnapshot(kind: LibraryKind? = nil) throws -> UnsavedHistorySnapshot {
        let clause = Self.unsavedHistoryWhere + (kind == nil ? "" : " AND i.kind=?")
        let values: [SQLValue] = kind.map { [.text($0.rawValue)] } ?? []
        let rows = try db.rows("SELECT i.id,printf('%!.17g|%!.17g|%s|%s',i.created,i.updated,COALESCE(json_extract(CAST(i.payload AS TEXT),'$.captureRevision'),''),COALESCE(json_extract(CAST(i.payload AS TEXT),'$.lastCopiedAt'),'')) AS version FROM items i WHERE " + clause + " ORDER BY i.id", values)
        var ids = [UUID](), captures = [UUID: String]()
        for row in rows {
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let version = row["version"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            ids.append(id); captures[id] = version
        }
        return UnsavedHistorySnapshot(kind: kind, ids: ids, captures: captures)
    }
    @discardableResult func clearUnsavedHistory(_ snapshot: UnsavedHistorySnapshot) throws -> [UUID] {
        guard !snapshot.ids.isEmpty else { return [] }
        let date = now()
        var eligible = [UUID]()
        // Acquire the writer lock before reading eligibility or payloads. A
        // rollback app's save must never be overwritten by a stale read.
        try db.transaction {
            let current = try unsavedHistorySnapshot(kind: snapshot.kind)
            var seen = Set<UUID>()
            for id in snapshot.ids where seen.insert(id).inserted {
                guard let version = snapshot.captures[id], current.captures[id] == version,
                      var value = try item(id) else { continue }
                value.deletedAt = date; value.onShelf = false; value.updatedAt = date; value.trashRevision = UUID()
                try put(value); eligible.append(id)
            }
        }
        guard !eligible.isEmpty else { return [] }
        invalidateShelfUndo(eligible); invalidateTrashUndo(eligible); changed(eligible)
        return eligible
    }
    func restore(_ ids: [UUID]) throws { try mutate(ids) { $0.deletedAt = nil; $0.onShelf = true; $0.trashRevision = nil }; invalidateShelfUndo(ids) }
    func markCopied(_ ids: [UUID]) throws { try mutate(ids) { $0.lastCopiedAt = self.now(); $0.captureRevision = UUID() } }
    func recordUpload(_ id: UUID, url: String) throws {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https",
              url.utf8.count <= 2048,
              var value = try item(id), value.deletedAt == nil else {
            throw HistoryFiles.Failure.unsafeFile
        }
        value.uploadedURL = url
        value.uploadedAt = now()
        try db.transaction { try put(value) }
        invalidateTrashUndo([id])
        changed([id])
    }
    func prune() throws {
        var expired = [LibraryRecord]()
        for kind in LibraryKind.allCases {
            let cutoff = now().addingTimeInterval(-Double(retentionDays(for: kind)) * 86400)
            // Text ordering may advance slightly beyond the wall clock after
            // a clock correction. Expiry must use actual capture time, never
            // that ordering timestamp. The derivative index keeps it bounded.
            let sql = kind == .text
                ? "SELECT i.payload FROM text_identity t JOIN items i ON i.id=t.item WHERE i.kind=? AND i.deleted IS NULL AND i.retained IS NULL AND t.captured<=?"
                : "SELECT payload FROM items WHERE kind=? AND deleted IS NULL AND retained IS NULL AND created<=?"
            expired += try LibrarySQL.decode(db.rows(sql, [.text(kind.rawValue), .real(cutoff.timeIntervalSince1970)])).filter { ($0.lastCapturedAt ?? $0.createdAt) <= cutoff }
        }
        if !expired.isEmpty { try trash(expired.map(\.id)) }
    }
    func collections() throws -> [LibraryCollection] {
        try db.rows("SELECT * FROM collections ORDER BY folded,id").map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryCollection(id: id, name: name, parentID: row["parent"]?.string.flatMap(UUID.init(uuidString:)))
        }
    }
    @discardableResult func createCollection(_ name: String, parent: UUID? = nil) throws -> UUID {
        let name = try cleanedName(name), all = try collections()
        if let parent { guard let value = all.first(where: { $0.id == parent }), value.parentID == nil else { throw HistoryFiles.Failure.invalidDestination } }
        guard !all.contains(where: { $0.parentID == parent && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        let id = UUID(); try db.execute("INSERT INTO collections VALUES(?,?,?,?)", [.text(id.uuidString), .text(name), parent.map { .text($0.uuidString) } ?? .null, .text(name.libraryFolded)]); changed(); return id
    }
    func renameCollection(_ id: UUID, name: String) throws {
        let name = try cleanedName(name), all = try collections()
        guard let collection = all.first(where: { $0.id == id }), !all.contains(where: { $0.id != id && $0.parentID == collection.parentID && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        try db.execute("UPDATE collections SET name=?,folded=? WHERE id=?", [.text(name), .text(name.libraryFolded), .text(id.uuidString)]); changed()
    }
    func removeCollection(_ id: UUID) throws {
        try db.transaction {
            let ids = try collections().filter { $0.id == id || $0.parentID == id }.map(\.id)
            for child in ids { try db.execute("DELETE FROM item_collections WHERE collection=?", [.text(child.uuidString)]) }
            for child in ids.filter({ $0 != id }) { try db.execute("DELETE FROM collections WHERE id=?", [.text(child.uuidString)]) }
            try db.execute("DELETE FROM collections WHERE id=?", [.text(id.uuidString)])
        }; changed()
    }
    func collections(for item: UUID) throws -> [LibraryCollection] {
        try db.rows("SELECT c.* FROM collections c JOIN item_collections m ON m.collection=c.id WHERE m.item=? ORDER BY c.folded,c.id", [.text(item.uuidString)]).map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryCollection(id: id, name: name, parentID: row["parent"]?.string.flatMap(UUID.init(uuidString:)))
        }
    }
    func pin(_ ids: [UUID], to collection: UUID? = nil) throws {
        if let collection { try assign(ids, to: collection, pinning: true) }
        else { try mutate(ids) { guard $0.deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }; $0.favorite = true; $0.retainedAt = $0.retainedAt ?? self.now() } }
    }
    func assign(_ ids: [UUID], to collection: UUID, movingFrom source: UUID? = nil, pinning: Bool = false) throws {
        let folders = try collections()
        guard folders.contains(where: { $0.id == collection }), source == nil || folders.contains(where: { $0.id == source }) else { throw HistoryFiles.Failure.invalidDestination }
        let sources = source.map { source in folders.filter { $0.id == source || $0.parentID == source }.map(\.id) } ?? []
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        for index in values.indices {
            if pinning { guard values[index].deletedAt == nil else { throw HistoryFiles.Failure.unsafeFile }; values[index].favorite = true }
            values[index].retainedAt = values[index].retainedAt ?? now(); try ensureOwned(&values[index])
        }
        try db.transaction {
            for value in values {
                try put(value); try db.execute("INSERT OR IGNORE INTO item_collections VALUES(?,?)", [.text(value.id.uuidString), .text(collection.uuidString)])
                for source in sources where source != collection { try db.execute("DELETE FROM item_collections WHERE item=? AND collection=?", [.text(value.id.uuidString), .text(source.uuidString)]) }
            }
        }; changed()
    }
    func unassign(_ id: UUID, from collection: UUID) throws { try db.execute("DELETE FROM item_collections WHERE item=? AND collection=?", [.text(id.uuidString), .text(collection.uuidString)]); changed() }
    func tags() throws -> [LibraryTag] { try db.rows("SELECT * FROM tags ORDER BY folded,id").map { row in guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }; return LibraryTag(id: id, name: name) } }
    func tags(for item: UUID) throws -> [LibraryTag] {
        try db.rows("SELECT t.* FROM tags t JOIN item_tags m ON m.tag=t.id WHERE m.item=? ORDER BY t.folded,t.id", [.text(item.uuidString)]).map { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string else { throw HistoryFiles.Failure.unsafeFile }
            return LibraryTag(id: id, name: name)
        }
    }
    private func cleanedName(_ name: String) throws -> String { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty, value.count <= 64, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw HistoryFiles.Failure.invalidDestination }; return value }
    func addTag(_ name: String, to ids: [UUID]) throws {
        let name = try cleanedName(name.trimmingCharacters(in: CharacterSet(charactersIn: "#"))), folded = name.libraryFolded
        let existing = try tags().first { $0.name.libraryFolded == folded }, tagID = existing?.id ?? UUID()
        var values = try ids.map { id -> LibraryRecord in guard let value = try item(id) else { throw HistoryFiles.Failure.unsafeFile }; return value }
        for index in values.indices { values[index].retainedAt = values[index].retainedAt ?? now(); try ensureOwned(&values[index]) }
        try db.transaction {
            if existing == nil { try db.execute("INSERT INTO tags VALUES(?,?,?)", [.text(tagID.uuidString), .text(name), .text(folded)]) }
            for value in values { try put(value); try db.execute("INSERT OR IGNORE INTO item_tags VALUES(?,?)", [.text(value.id.uuidString), .text(tagID.uuidString)]); try put(value) }
        }; changed()
    }
    func removeTag(_ tag: UUID, from itemID: UUID? = nil) throws {
        let affected = try db.rows("SELECT item FROM item_tags WHERE tag=?", [.text(tag.uuidString)]).compactMap { $0["item"]?.string.flatMap(UUID.init(uuidString:)) }
        try db.transaction {
            if let itemID { try db.execute("DELETE FROM item_tags WHERE tag=? AND item=?", [.text(tag.uuidString), .text(itemID.uuidString)]) }
            else { try db.execute("DELETE FROM item_tags WHERE tag=?", [.text(tag.uuidString)]); try db.execute("DELETE FROM tags WHERE id=?", [.text(tag.uuidString)]) }
            for id in affected { if let value = try item(id) { try put(value) } }
        }; changed()
    }
    func renameTag(_ id: UUID, name: String) throws {
        let name = try cleanedName(name)
        let existing = try tags()
        guard existing.contains(where: { $0.id == id }), !existing.contains(where: { $0.id != id && $0.name.libraryFolded == name.libraryFolded }) else { throw HistoryFiles.Failure.invalidDestination }
        let affected = try db.rows("SELECT item FROM item_tags WHERE tag=?", [.text(id.uuidString)]).compactMap { $0["item"]?.string.flatMap(UUID.init(uuidString:)) }
        try db.transaction { try db.execute("UPDATE tags SET name=?,folded=? WHERE id=?", [.text(name), .text(name.libraryFolded), .text(id.uuidString)]); for id in affected { if let value = try item(id) { try put(value) } } }; changed()
    }
    func backup(to url: URL) throws { try db.backup(to: url) }
    func writePrivate(_ data: Data, to url: URL) throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: url.path) || url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw HistoryFiles.Failure.unsafeFile }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID())")
        guard FileManager.default.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw HistoryFiles.Failure.unsafeFile }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: url) }
    }
    private func changed(_ ids: [UUID] = []) {
        changedIDs = Set(ids)
        changedKinds = ids.isEmpty ? Set(LibraryKind.allCases) : Set(ids.compactMap { try? item($0)?.kind })
        revision += 1
    }
    /// Used by local import and large synthetic fixtures. One transaction and
    /// one publication keep the UI from re-reading every intermediate record.
    func importRecords(_ records: [LibraryRecord]) throws {
        var seen = Set<UUID>()
        for record in records {
            guard seen.insert(record.id).inserted, (record.text?.utf8.count ?? 0) <= TextClipboardWatcher.maximumDataBytes,
                  record.note.utf8.count <= TextClipboardWatcher.maximumDataBytes, try item(record.id) == nil else { throw HistoryFiles.Failure.unsafeFile }
            if record.kind == .image { guard let file = record.fileURL, files.isRegularFile(file) else { throw HistoryFiles.Failure.unsafeFile } }
            if record.kind == .link { guard let url = record.linkURL, LinkIdentity.normalized(url) == record.normalizedURL else { throw HistoryFiles.Failure.unsafeFile } }
        }
        try db.transaction { for var record in records { if record.retainedAt != nil { try ensureOwned(&record) }; try put(record) } }; changed()
    }
}
