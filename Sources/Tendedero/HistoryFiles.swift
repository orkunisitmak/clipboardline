import Foundation

/// All destructive app operations use recoverable Trash. Ownership is
/// checked from the current filesystem, never from a user-visible label.
struct HistoryFiles {
    enum Failure: Error, LocalizedError {
        case unsafeFile, invalidDestination, tooManyCollisions
        var errorDescription: String? {
            switch self {
            case .unsafeFile: L("File could not be read or safely saved")
            case .invalidDestination: L("Choose a valid destination or a unique name (1–64 characters)")
            case .tooManyCollisions: L("A free filename could not be found")
            }
        }
    }
    struct ExportResult {
        var copies: [URL] = []
        var failed: [URL] = []
    }

    let inbox: URL
    let moveToTrash: (URL) throws -> URL
    private let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp", "mov", "mp4"]
    var favoritesFolder: URL { inbox.appendingPathComponent("Favorites", isDirectory: true) }

    init(inbox: URL, moveToTrash: @escaping (URL) throws -> URL = Self.systemTrash) {
        self.inbox = inbox.standardizedFileURL
        self.moveToTrash = moveToTrash
    }

    static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw Failure.unsafeFile }
        return result as URL
    }

    func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func isClipboardCopy(_ url: URL) -> Bool {
        isNamedCopy(url, prefix: "Clipboard ", folder: inbox, allowed: ["png"])
    }

    func isFavoriteCopy(_ url: URL) -> Bool {
        isNamedCopy(url, prefix: "Favorite ", folder: favoritesFolder, allowed: extensions)
    }

    func isAppCopy(_ url: URL) -> Bool { isClipboardCopy(url) || isFavoriteCopy(url) }

    /// Markup flattens to PNG even when the original was JPEG/HEIC. Preserve
    /// the recognizable filename while ensuring the extension matches bytes.
    static func exportName(for url: URL, originalPath: String?) -> String {
        guard let originalPath else { return url.lastPathComponent }
        let original = URL(fileURLWithPath: originalPath)
        guard original.pathExtension.lowercased() != url.pathExtension.lowercased() else { return original.lastPathComponent }
        return original.deletingPathExtension().lastPathComponent + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
    }

    /// An item the user named exports under that name, as on Windows; the file keeps its extension.
    static func exportName(for url: URL, originalPath: String?, title: String?) -> String {
        let base = exportName(for: url, originalPath: originalPath)
        var label = (title ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (base as NSString).pathExtension
        // File names are limited to 255 bytes, so cut on whole characters within what the extension leaves.
        var budget = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        label = String(label.prefix(100).prefix { budget -= String($0).utf8.count; return budget >= 0 }).trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        guard !label.isEmpty else { return base }
        return ext.isEmpty ? label : label + "." + ext
    }

    private func isNamedCopy(_ url: URL, prefix: String, folder: URL, allowed: Set<String>) -> Bool {
        let folder = folder.standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent().path == folder.path,
              folder.resolvingSymlinksInPath().path == folder.path,
              allowed.contains(url.pathExtension.lowercased()), isRegularFile(url) else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    func files(in folder: URL, matching predicate: (URL) -> Bool) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []).filter(predicate)
    }

    func makeFavoriteCopy(of original: URL) throws -> URL {
        guard isRegularFile(original), extensions.contains(original.pathExtension.lowercased()),
              inbox.resolvingSymlinksInPath().path == inbox.path,
              favoritesFolder.resolvingSymlinksInPath().path == favoritesFolder.path else { throw Failure.unsafeFile }
        try FileManager.default.createDirectory(at: favoritesFolder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = favoritesFolder.appendingPathComponent("Favorite \(UUID()).\(original.pathExtension.lowercased())")
        try FileManager.default.copyItem(at: original, to: target)
        guard isRegularFile(target), favoritesFolder.resolvingSymlinksInPath().path == favoritesFolder.path else {
            throw Failure.unsafeFile
        }
        // Set private permissions before the new path enters persisted history.
        // If this fails, the copy stays untracked for recovery; no permanent delete.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    @discardableResult
    func trashAppCopy(_ url: URL) throws -> URL {
        guard isAppCopy(url) else { throw Failure.unsafeFile }
        return try moveToTrash(url)
    }

    func export(_ sources: [(url: URL, name: String)], to folder: URL) throws -> ExportResult {
        guard folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw Failure.invalidDestination
        }
        var result = ExportResult()
        for source in sources {
            guard isRegularFile(source.url) else { result.failed.append(source.url); continue }
            let safeName = (source.name as NSString).lastPathComponent
            let base = (safeName as NSString).deletingPathExtension
            let ext = (safeName as NSString).pathExtension
            var copied = false
            for suffix in 1...10_000 {
                let name = suffix == 1 ? safeName : "\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
                let target = folder.appendingPathComponent(name)
                do {
                    // copyItem fails if the destination exists; it cannot
                    // overwrite a file even if it appeared after our check.
                    try FileManager.default.copyItem(at: source.url, to: target)
                    result.copies.append(target)
                    copied = true
                    break
                } catch {
                    if FileManager.default.fileExists(atPath: target.path) { continue }
                    break
                }
            }
            if !copied { result.failed.append(source.url) }
        }
        return result
    }
}
