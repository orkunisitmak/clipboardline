import AppKit
import Combine
import ImageIO
import Vision

/// Derived search data never changes record payloads, dates, pins or originals.
/// Image recognition and model prediction run independently of grid thumbnails.
@MainActor final class LibraryImageSearch {
    private weak var store: LibraryStore?
    private let worker: ImageSearchWorker
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var scheduled: DispatchWorkItem?
    init(store: LibraryStore, modelFolder: URL? = Bundle.main.resourceURL?.appendingPathComponent("CLIP")) {
        self.store = store; worker = ImageSearchWorker(database: store.databaseURL, modelFolder: modelFolder)
        subscription = store.$revision.dropFirst().sink { [weak self, weak store] _ in
            if store?.changedKinds.contains(.image) == true { self?.refresh() }
        }
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    func stop() { scheduled?.cancel(); subscription?.cancel(); timer?.invalidate(); worker.cancel() }
    func refresh() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.worker.scan { [weak self] done, total, changed in
                guard let store = self?.store else { return }
                store.imageSearchStatus = done < total ? String(format: L("Reading images… %d of %d"), done, total) : ""
                if changed { store.imageSearchChanged() }
            }
        }
        scheduled = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func resolve(_ query: LibraryQuery, completion: @escaping (LibraryQuery) -> Void) {
        var clean = query; clean.visualIDs = []
        guard query.searchMode != .text, query.kind == nil || query.kind == .image,
              !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(clean); return }
        guard let store else { completion(clean); return }
        var corpus = clean; corpus.search = ""; corpus.kind = .image
        // Rank within the chosen folder/tag/pin/date scope. A strong match
        // elsewhere must not suppress a valid match in the current view.
        store.queryIDsAsync(corpus) { [weak self] result in
            guard let self, case let .success(ids) = result else { completion(clean); return }
            self.worker.search(query.search, eligibleIDs: Set(ids)) { ids in clean.visualIDs = ids; completion(clean) }
        }
    }
}

enum VisualRanking {
    static let dimensions = 512
    static func pack(_ values: [[Float]]) -> Data {
        let values = values.filter { $0.count == dimensions && $0.allSatisfy(\.isFinite) }.prefix(4).flatMap { $0 }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func score(_ query: [Float], _ data: Data) -> Double? {
        guard query.count == dimensions, query.allSatisfy(\.isFinite), !data.isEmpty,
              data.count <= dimensions * 16, data.count % (dimensions * 4) == 0 else { return nil }
        var best = -Double.infinity
        data.withUnsafeBytes { bytes in
            for start in stride(from: 0, to: data.count, by: dimensions * 4) {
                var sum: Float = 0
                for i in 0..<dimensions { sum += query[i] * bytes.loadUnaligned(fromByteOffset: start + i * 4, as: Float.self) }
                if sum.isFinite { best = max(best, Double(sum)) }
            }
        }
        return best.isFinite ? best : nil
    }
    static func matches(_ values: [(UUID, Double)]) -> [UUID] {
        let scores = values.filter { $0.1.isFinite }, best = scores.map(\.1).max() ?? 0
        let mean = scores.isEmpty ? 0 : scores.reduce(0) { $0 + $1.1 } / Double(scores.count)
        let spread = scores.isEmpty ? 1 : max(0.01, sqrt(scores.reduce(0) { $0 + pow($1.1 - mean, 2) } / Double(scores.count)))
        return scores.filter { $0.1 >= max(0.22, best - 0.045) && (scores.count < 8 || $0.1 >= 0.30 || ($0.1 - mean) / spread >= 1.25) }
            .sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 > $1.1 }.prefix(200).map(\.0)
    }
}

final class ImageSearchWorker: @unchecked Sendable {
    static let version = "vision-mobileclip-s2-3e0a7bf-v1"
    private let database: URL
    private let modelFolder: URL?
    private let queue = DispatchQueue(label: "local.clipboardline.image-search.index", qos: .utility)
    private let queries = DispatchQueue(label: "local.clipboardline.image-search.query", qos: .userInitiated)
    private let stateLock = NSLock(), modelLock = NSLock()
    private var generation = 0
    private var modelLoaded = false
    private var model: Clip?
    private var cachedQuery = ""
    private var cachedVector: [Float]?
    init(database: URL, modelFolder: URL?) { self.database = database; self.modelFolder = modelFolder }
    func cancel() { stateLock.lock(); generation += 1; stateLock.unlock() }
    private func current(_ value: Int) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return generation == value }
    private func clip() -> Clip? {
        modelLock.lock(); defer { modelLock.unlock() }
        if !modelLoaded { modelLoaded = true; model = modelFolder.flatMap(Clip.init(folder:)) }
        return model
    }
    static func fingerprint(_ url: URL) -> String? {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]), value.isRegularFile == true, value.isSymbolicLink != true,
              let size = value.fileSize, size > 0, size <= 128 * 1024 * 1024, let date = value.contentModificationDate else { return nil }
        return "\(url.path):\(size):\(date.timeIntervalSince1970)"
    }
    static func recognize(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else { throw HistoryFiles.Failure.unsafeFile }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(65536))
    }
    func scan(progress: @escaping @MainActor (Int, Int, Bool) -> Void) {
        stateLock.lock(); generation += 1; let token = generation; stateLock.unlock()
        queue.async { [self] in
            guard current(token), let db = try? LibraryDatabase(url: database, verify: false) else { return }
            do {
                let expectedVersion = modelFolder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model-source.json").path) } == true ? Self.version : "vision-ocr-v1"
                let rows = try db.rows("SELECT i.id,i.path,a.fingerprint,a.version FROM items i LEFT JOIN image_analysis a ON a.item=i.id WHERE i.kind='image' AND i.deleted IS NULL ORDER BY i.created DESC")
                let todo = rows.compactMap { row -> (UUID, URL, String)? in
                    guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let path = row["path"]?.string else { return nil }
                    let url = URL(fileURLWithPath: path)
                    guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"].contains(url.pathExtension.lowercased()), let key = Self.fingerprint(url), row["fingerprint"]?.string != key || row["version"]?.string != expectedVersion else { return nil }
                    return (id, url, key)
                }
                if todo.isEmpty { DispatchQueue.main.async { if self.current(token) { progress(0, 0, false) } }; return }
                DispatchQueue.main.async { if self.current(token) { progress(0, todo.count, false) } }
                let model = clip(), version = model == nil ? "vision-ocr-v1" : Self.version
                var dirty = false, lastReport = Date.distantPast
                for (index, job) in todo.enumerated() {
                    guard current(token) else { return }
                    autoreleasepool {
                        do {
                            let text = try Self.recognize(job.1), vectors = VisualRanking.pack(model?.embed(imageAt: job.1) ?? [])
                            guard current(token), Self.fingerprint(job.1) == job.2 else { return }
                            try db.execute("INSERT INTO image_analysis(item,path,fingerprint,version,content,ocr,vectors) SELECT id,path,?,?,?,?,? FROM items WHERE id=? AND path=? AND deleted IS NULL ON CONFLICT(item) DO UPDATE SET path=excluded.path,fingerprint=excluded.fingerprint,version=excluded.version,content=excluded.content,ocr=excluded.ocr,vectors=excluded.vectors", [.text(job.2), .text(version), .text(text.searchFolded), .text(text), .blob(vectors), .text(job.0.uuidString), .text(job.1.path)])
                            dirty = true
                        } catch { /* A bad image cannot block the remaining records. */ }
                    }
                    if Date().timeIntervalSince(lastReport) >= 1 || index == todo.count - 1 {
                        let changed = dirty; dirty = false; lastReport = Date()
                        DispatchQueue.main.async { if self.current(token) { progress(index + 1, todo.count, changed) } }
                    }
                }
            } catch { DispatchQueue.main.async { if self.current(token) { progress(0, 0, false) } } }
        }
    }
    func search(_ text: String, eligibleIDs: Set<UUID>, completion: @escaping @MainActor ([UUID]) -> Void) {
        queries.async { [self] in
            if cachedQuery != text { cachedQuery = text; cachedVector = clip()?.embed(text: text) }
            var ids = [UUID]()
            if let vector = cachedVector, let db = try? LibraryDatabase(url: database, readOnly: true, verify: false),
               let rows = try? db.rows("SELECT a.item,a.vectors FROM image_analysis a JOIN items i ON i.id=a.item AND i.path=a.path WHERE a.version=?", [.text(Self.version)]) {
                ids = VisualRanking.matches(rows.compactMap { row in
                    guard let id = row["item"]?.string.flatMap(UUID.init(uuidString:)), eligibleIDs.contains(id), let data = row["vectors"]?.data, let score = VisualRanking.score(vector, data) else { return nil }
                    return (id, score)
                })
            }
            let result = ids; DispatchQueue.main.async { completion(result) }
        }
    }
}
