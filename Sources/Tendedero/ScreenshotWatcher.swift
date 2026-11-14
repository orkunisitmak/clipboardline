import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// Screen recordings carry no tag, so they are only picked up in
    /// Tendedero's own folder, where nothing else is saved.
    private let acceptsRecordings: Bool
    private var known: Set<String>?
    /// What the folder held when it was replaced. The descriptor on the old
    /// folder can still fire and list the replacement by path, so its images
    /// may already be reported when the replacement is first listed.
    private var knownBeforeReplacement: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var pendingFolderCheck: DispatchWorkItem?
    private var identityTimer: DispatchSourceTimer?
    private var identityCheckInFlight = false
    /// Identity of the directory currently found at folder.
    private var folderIdentity: FolderIdentity?
    /// Invalidates a listing or open that started before the folder changed.
    private var generation = 0
    /// A `start()` that is still waiting on the folder, off the main thread.
    private var starting = false
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A capture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while an open or listing was still pending.
    private var stopped = false
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    private struct FolderIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    /// `anyImage` takes every new image even on the Desktop, for a folder
    /// the user chose to watch.
    init(folder: URL? = nil, anyImage: Bool = false, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = !anyImage
            && self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
        acceptsRecordings = self.folder.standardizedFileURL.path == Inbox.folder.standardizedFileURL.path
    }

    static func screenshotFolder() -> URL {
        let fm = FileManager.default
        // Read fresh through cfprefsd: inbox mode changes this value at runtime.
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let domain = "com.apple.screencapture" as CFString
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

    /// The folder is opened off the main thread, because `open()` blocks while
    /// macOS asks whether Tendedero may look inside it. On the Desktop that is
    /// the consent prompt, and it waits for an answer. Asking from
    /// `applicationDidFinishLaunching` meant the app had not finished launching
    /// while that was pending: no status item appeared, and the signal sources
    /// that put the screenshot settings back never ran.
    func start() {
        stopped = false
        guard parentSource == nil, source == nil, !starting else { return }
        starting = true
        let parent = folder.deletingLastPathComponent()
        let expectedGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let parentFD = open(parent.path, O_EVTONLY)
            let previousIdentity = self.identityOfFolder()
            let folderFD = open(self.folder.path, O_EVTONLY)
            let identity = self.identityOfFolder()
            DispatchQueue.main.async {
                self.starting = false
                self.watchParent(parentFD)
                self.startIdentityMonitor()
                self.folderIdentity = identity
                if previousIdentity == identity {
                    self.watch(folderFD, generation: expectedGeneration, identity: identity)
                } else {
                    if folderFD >= 0 { close(folderFD) }
                    self.openFolderIfAvailable()
                }
            }
        }
    }

    /// Tracks the containing directory so replacing the watched folder can be
    /// detected even though its original descriptor still points at the old inode.
    private func watchParent(_ fd: Int32) {
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            NSLog("Tendedero: cannot watch parent of \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleFolderCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        parentSource = src
    }

    /// Starts the child watcher before listing so a capture that lands in
    /// between is not lost.
    private func watch(_ fd: Int32, generation expectedGeneration: Int, identity expectedIdentity: FolderIdentity?) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard expectedGeneration == generation else {
            if fd >= 0 { close(fd) }
            openFolderIfAvailable()
            return
        }
        guard fd >= 0 else {
            NSLog("Tendedero: cannot watch \(folder.path)")
            return
        }
        guard expectedIdentity == folderIdentity else {
            close(fd)
            reconcileFolder(expectedIdentity)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        refresh()
    }

    private func openFolderIfAvailable() {
        guard !stopped, source == nil, !starting, !listing, folderIdentity != nil else { return }
        starting = true
        let expectedGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let previousIdentity = self.identityOfFolder()
            let fd = open(self.folder.path, O_EVTONLY)
            let identity = self.identityOfFolder()
            DispatchQueue.main.async {
                guard previousIdentity == identity else {
                    if fd >= 0 { close(fd) }
                    self.starting = false
                    self.scheduleFolderCheck()
                    return
                }
                self.watch(fd, generation: expectedGeneration, identity: identity)
            }
        }
    }

    private func startIdentityMonitor() {
        guard identityTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.readFolderIdentity() }
        timer.resume()
        identityTimer = timer
    }

    private func scheduleFolderCheck() {
        pendingFolderCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readFolderIdentity() }
        pendingFolderCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func readFolderIdentity() {
        guard !stopped, !identityCheckInFlight else { return }
        identityCheckInFlight = true
        let expectedGeneration = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let identity = self.identityOfFolder()
            DispatchQueue.main.async {
                self.identityCheckInFlight = false
                guard !self.stopped, expectedGeneration == self.generation else { return }
                self.reconcileFolder(identity)
            }
        }
    }

    private func reconcileFolder(_ currentIdentity: FolderIdentity?) {
        guard !stopped else { return }
        guard currentIdentity != folderIdentity else { return }
        folderIdentity = currentIdentity
        generation += 1
        pending?.cancel()
        pending = nil
        knownBeforeReplacement.formUnion(known ?? [])
        known = nil
        missed = false
        source?.cancel()
        source = nil
        openFolderIfAvailable()
    }

    private func identityOfFolder() -> FolderIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FolderIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, and a listing that lands
    /// afterwards is dropped.
    func stop() {
        stopped = true
        missed = false
        pending?.cancel()
        pending = nil
        pendingFolderCheck?.cancel()
        pendingFolderCheck = nil
        identityTimer?.cancel()
        identityTimer = nil
        generation += 1
        source?.cancel()
        source = nil
        parentSource?.cancel()
        parentSource = nil
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reads the folder off the main thread. Sorting by creation date and
    /// reading it back costs one filesystem call per file, and this folder can
    /// be the Desktop, so none of it belongs on the main thread.
    private func refresh() {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        let requestedGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let files = self.listFolder()
            let settled = files.filter { self.creationDate($0) < self.launchDate }
            let candidates = files.filter { self.isCandidate($0) }
            DispatchQueue.main.async {
                self.adopt(files, settled, candidates, generation: requestedGeneration)
            }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func adopt(_ files: [URL], _ settled: [URL], _ candidates: [URL], generation requestedGeneration: Int) {
        listing = false
        guard !stopped else { return }
        guard requestedGeneration == generation else {
            openFolderIfAvailable()
            return
        }
        // The first listing adopts everything that was already there when the
        // app launched. Later ones compare against the previous listing.
        let first = known == nil
        let base = known ?? Set(settled.map(\.path)).union(knownBeforeReplacement)
        for url in candidates where !base.contains(url.path) {
            onNew(url)
        }
        knownBeforeReplacement = []
        known = Set(files.map(\.path))
        if !first { onChange() }
        if missed {
            missed = false
            refresh()
        }
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    func isCandidate(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        if isRecordingFile(url) { return acceptsRecordings }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? isScreenCapture(url) : true
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
