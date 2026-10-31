import AppKit

struct LinkMetadata: Equatable {
    var title: String?
    var author: String?
    var thumbnail: Data?
}

@MainActor final class LinkMetadataService {
    typealias Fetch = (URL) async throws -> LinkMetadata
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "linkMetadataEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "linkMetadataEnabled") }
    }
    let store: LibraryStore
    private let fetch: Fetch
    private let enabled: () -> Bool
    private var wanted = [UUID]()
    private var running = [UUID: Task<Void, Never>]()
    private var cache = [String: LinkMetadata]()
    private var generation = 0
    private(set) var peakConcurrency = 0
    var pendingCount: Int { running.count }
    init(store: LibraryStore, enabled: (() -> Bool)? = nil, fetch: Fetch? = nil) {
        self.store = store; self.enabled = enabled ?? { Self.isEnabled }; self.fetch = fetch ?? Self.fetchMetadata
    }
    /// The newest visible requests replace queued work. At most two network
    /// operations run, so a fling cannot queue every link it passes.
    func request(_ ids: [UUID], force: Bool = false) {
        guard enabled() else { stop(); return }
        if force {
            stop()
            for id in ids {
                if let record = try? store.item(id), let url = record.linkURL { cache.removeValue(forKey: cacheKey(record, url: url)) }
                try? store.update(id) { $0.metadataState = "pending"; $0.metadataAttemptedAt = nil }
            }
        }
        wanted = Array(NSOrderedSet(array: ids).array.compactMap { $0 as? UUID })
        schedule()
    }
    private func cacheKey(_ record: LibraryRecord, url: URL) -> String { LinkIdentity.youtubeID(url).map { "youtube:\($0)" } ?? record.normalizedURL ?? url.absoluteString }
    func stop() { generation += 1; wanted.removeAll(); for task in running.values { task.cancel() }; running.removeAll() }
    private func schedule() {
        guard enabled() else { stop(); return }
        for id in wanted {
            guard running.count < 2 else { return }
            guard running[id] == nil, let record = try? store.item(id), record.deletedAt == nil, let url = record.linkURL else { continue }
            guard LinkIdentity.mayFetchMetadata(url) else { if record.metadataState != "blocked" { try? store.update(id) { $0.metadataState = "blocked" } }; continue }
            guard record.metadataState != "ready",
                  record.metadataAttemptedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { continue }
            let key = cacheKey(record, url: url)
            let cached = cache[key]
            let token = generation
            running[id] = Task { [weak self] in
                guard let self, !Task.isCancelled, token == self.generation else { return }
                let result: Result<LinkMetadata, Error>
                do { if let cached { result = .success(cached) } else { result = .success(try await fetch(url)) } } catch { result = .failure(error) }
                guard !Task.isCancelled, token == self.generation else { return }
                await self.complete(id, key: key, token: token, result: result)
            }
            peakConcurrency = max(peakConcurrency, running.count)
        }
    }
    private func complete(_ id: UUID, key: String, token: Int, result: Result<LinkMetadata, Error>) async {
        defer { if token == generation { running[id] = nil; schedule() } }
        guard enabled(), let record = try? store.item(id), record.deletedAt == nil else { return }
        do {
            var thumbnail: String?
            if case let .success(metadata) = result {
                cache[key] = metadata; if cache.count > 128 { cache.removeValue(forKey: cache.keys.first!) }
                while cache.values.reduce(0, { $0 + ($1.thumbnail?.count ?? 0) }) > 16 * 1024 * 1024 { cache.removeValue(forKey: cache.keys.first!) }
                if let data = metadata.thumbnail, data.count <= 5 * 1024 * 1024 {
                    let folder = store.thumbnailsFolder
                    guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else { throw HistoryFiles.Failure.unsafeFile }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let file = folder.appendingPathComponent("\(id)-\(UUID()).image")
                    try store.writePrivate(data, to: file)
                    if await Task.detached(priority: .utility, operation: { decodeThumbnail(file, maxPixels: 640) != nil }).value { thumbnail = file.path }
                    else { try? FileManager.default.removeItem(at: file) }
                }
            }
            guard token == generation, !Task.isCancelled, enabled() else { return }
            try store.update(id) { value in
                value.metadataAttemptedAt = Date()
                switch result {
                case let .success(metadata):
                    // A user supplied title always wins over network metadata.
                    value.metadataTitle = metadata.title.map { String($0.prefix(500)) }
                    value.author = metadata.author.map { String($0.prefix(200)) }; value.thumbnailPath = thumbnail ?? value.thumbnailPath
                    value.metadataState = "ready"
                case .failure: value.metadataState = "failed"
                }
            }
            if let thumbnail, let old = record.thumbnailPath, old != thumbnail {
                let file = URL(fileURLWithPath: old)
                if file.deletingLastPathComponent() == store.thumbnailsFolder, file.resolvingSymlinksInPath() == file { try? FileManager.default.removeItem(at: file) }
            }
        } catch { wanted.removeAll { $0 == id }; store.notice = L("Link preview could not be saved; the link is kept") }
    }
    static func youtubeMetadata(_ data: Data) throws -> (LinkMetadata, URL?) {
        struct Response: Decodable { let title: String?; let author_name: String?; let thumbnail_url: String? }
        guard data.count <= 256 * 1024 else { throw HistoryFiles.Failure.unsafeFile }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let imageURL = response.thumbnail_url.flatMap(URL.init(string:)).flatMap { url -> URL? in
            guard url.scheme == "https", let host = url.host?.lowercased(), host == "i.ytimg.com" || host.hasSuffix(".ytimg.com") else { return nil }; return url
        }
        return (LinkMetadata(title: response.title, author: response.author_name), imageURL)
    }
    static func fetchMetadata(_ url: URL) async throws -> LinkMetadata {
        guard PublicLinkDestination(url) != nil else { throw PublicLinkError.blockedURL }
        let network = PublicLinkNetwork()
        if let video = LinkIdentity.youtubeID(url) {
            var endpoint = URLComponents(string: "https://www.youtube.com/oembed")!
            endpoint.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(video)"), URLQueryItem(name: "format", value: "json")]
            let response = try await network.fetch(endpoint.url!, limit: 256 * 1024,
                allowed: { $0.host == "www.youtube.com" })
            var (metadata, thumbnail) = try youtubeMetadata(response.body)
            if let thumbnail {
                metadata.thumbnail = try? await network.fetch(thumbnail, limit: 5 * 1024 * 1024,
                    allowed: { $0.host == "i.ytimg.com" || $0.host?.hasSuffix(".ytimg.com") == true }).body
            }
            return metadata
        }
        let response = try await network.fetch(url, limit: 512 * 1024)
        let type = response.headers["content-type"]?.lowercased() ?? ""
        guard type.contains("text/html") || type.contains("application/xhtml+xml") else { return LinkMetadata(title: response.url.host) }
        let parsed = try await Task.detached(priority: .utility) {
            try PublicLinkHTMLMetadata(data: response.body, url: response.url, contentType: type)
        }.value
        var result = LinkMetadata(title: parsed.title, author: parsed.author)
        if let thumbnail = parsed.thumbnailURL {
            result.thumbnail = try? await network.fetch(thumbnail, limit: 5 * 1024 * 1024).body
        }
        return result
    }
}
