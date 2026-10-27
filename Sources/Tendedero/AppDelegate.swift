import AppKit
import ApplicationServices
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

/// Monotonic timings for the native presentation boundary. Contains no app
/// identifiers, field values or clipboard data; the isolated UI harness can
/// inspect a bounded sample without querying an external accessibility tree.
struct ShelfPresentationTiming {
    let phase: String
    let elapsedMilliseconds: Double
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line: Line
#if STANDALONE_TESTS
    @objc var shelfHitGeometryUpdateCountForTesting: Int { line.shelfHitGeometryUpdateCount }
#endif
    private let clipboardSource: (any ClipboardSource)?
    private let watchesFiles: Bool
    private let startupError: String?
    private let isolatedCopyBoard: NSPasteboard?
    private let ownsKeyboardFocus: @MainActor () -> Bool

    override init() {
        do { line = Line(library: try LibraryStore(defaults: .standard, inbox: Inbox.folder), pruneOnLoad: false); startupError = nil }
        catch {
            startupError = L("Library could not be opened. Existing history is kept; capture is paused.")
            line = Line(defaults: UserDefaults(suiteName: "local.clipboardline.recovery")!, inbox: Inbox.folder.appendingPathComponent("Recovery"), breeze: false, pruneOnLoad: false)
        }
        clipboardSource = nil; watchesFiles = true
        isolatedCopyBoard = nil
        ownsKeyboardFocus = { NSApp?.keyWindow != nil }
        directPaste = DirectPasteCoordinator()
        super.init()
    }

    init(line: Line, clipboardSource: (any ClipboardSource)? = nil, watchesFiles: Bool = true, copyPasteboard: NSPasteboard? = nil, directPaste: DirectPasteCoordinator? = nil, r2: R2UploadCoordinator? = nil, ownsKeyboardFocus: (@MainActor () -> Bool)? = nil) {
        self.line = line
        startupError = nil
        isolatedCopyBoard = copyPasteboard
        self.directPaste = directPaste ?? DirectPasteCoordinator()
        self.injectedR2Coordinator = r2
        self.ownsKeyboardFocus = ownsKeyboardFocus ?? { NSApp?.keyWindow != nil }
        self.clipboardSource = clipboardSource; self.watchesFiles = watchesFiles
        super.init()
    }
    private(set) var panel: LinePanel!
    private(set) var shelfPresentationTimings = [ShelfPresentationTiming]()
    private func recordShelfPresentation(_ phase: String, since start: TimeInterval) {
        let milliseconds = max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000
        shelfPresentationTimings.append(.init(phase: phase, elapsedMilliseconds: milliseconds))
        if shelfPresentationTimings.count > 128 { shelfPresentationTimings.removeFirst(shelfPresentationTimings.count - 128) }
        DirectPasteDiagnostics.log.debug("Shelf presentation phase=\(phase, privacy: .public) durationMS=\(milliseconds, privacy: .public)")
    }
    private var statusItem: NSStatusItem!
    #if STANDALONE_TESTS
    var statusToolTipForTesting: String { statusItem?.button?.toolTip ?? "" }
    var statusDimmedForTesting: Bool { statusItem?.button?.appearsDisabled ?? false }
    #endif
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    private var folderWatchers: [ScreenshotWatcher] = []
    private lazy var clipboardWatcher: ClipboardWatcher = {
        let callback: (URL) -> Void = { [weak self] in self?.hangCapture($0) }
        if let clipboardSource { return ClipboardWatcher(source: clipboardSource, folder: line.historyFiles.inbox, onImage: callback) }
        return ClipboardWatcher(onImage: callback)
    }()
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var copyHotKey: HotKey?
    private var uploadHotKey: HotKey?
    private var libraryHotKey: HotKey?
    private var searchHotKey: HotKey?
    private let directPaste: DirectPasteCoordinator
    private var injectedR2Coordinator: R2UploadCoordinator?
    private(set) lazy var r2Coordinator: R2UploadCoordinator = injectedR2Coordinator ?? R2UploadCoordinator(
        store: line.library,
        defaults: line.defaults,
        secrets: watchesFiles ? KeychainR2SecretStore() : InMemoryR2SecretStore(),
        writeLink: { [weak self] url in
            ClipboardTransfer.write(ClipboardTransfer.linkItems([url.absoluteString]), to: self?.isolatedCopyBoard ?? .general)
        }
    )
    private var pasteFocusHandoffDepth = 0
    private lazy var imageTextCopy: ImageTextCopy? = line.library.map { store in
        ImageTextCopy(store: store, writeText: { [weak self] text in
            ClipboardTransfer.write(ClipboardTransfer.textItems([text]), to: self?.isolatedCopyBoard ?? .general)
        })
    }
    private(set) var commandPalette: CommandPalette?
    private(set) var tagPicker: TagPicker?
    private(set) var nameAndPinPicker: NameAndPinPicker?
    private var isPasting = false
    private(set) var preview: ImagePreview?
    private(set) var textPreview: TextPreview?
    private(set) var linkPreview: LinkPreview?
    private(set) var libraryController: LibraryWindowController?
    private lazy var metadataService: LinkMetadataService? = line.library.map { LinkMetadataService(store: $0) }
    private(set) var previewSession: ShelfPreviewSession?
    private(set) var pinFolderPicker: PinFolderPicker?
    private var previewDisplayedID: UUID?
    private(set) var previewWindow: ActionPreviewPanel?
    private var emptyPreview: EmptyShelfPreview?
    private lazy var textWatcher: TextClipboardWatcher = {
        let callback: (String) -> Void = { [weak self] text in
            // Text capture only changes data. It never reveals the shelf,
            // changes the active shelf, or requests keyboard focus.
            self?.receiveCopiedText(text)
        }
        let link: (URL) -> Void = { [weak self] url in if let record = self?.line.links.add(url) { self?.metadataService?.request([record.id]) } }
        if let clipboardSource { return TextClipboardWatcher(source: clipboardSource, onText: callback, onLink: link, capturesText: { TextClipboardWatcher.isEnabled }, capturesLinks: { LinkHistory.isEnabled }) }
        return TextClipboardWatcher(onText: callback, onLink: link, capturesText: { TextClipboardWatcher.isEnabled }, capturesLinks: { LinkHistory.isEnabled })
    }()
    private var shortcutRecorder: ShortcutRecorder?
    private var shortcutRestoreWarning: String?
    private(set) var settingsController: SettingsWindowController?
    private lazy var appUpdates: AppUpdateController = {
        let controller = AppUpdateController(enabled: watchesFiles)
        controller.canQuit = { [weak self] in
            guard let self else { return false }
            return (self.flushPreviewEdits()) && (self.libraryController?.flush() ?? true)
        }
        return controller
    }()
    private let updateNotifications = UpdateNotifications()
    private var updateWakeObserver: NSObjectProtocol?
    private var operationBusy = false
    private var previousApplication: NSRunningApplication?
    private lazy var keyboard = LineKeyboard(line: line,
        onCopy: { [weak self] _ in self?.line.copySelection() },
        onPreview: { [weak self] in self?.showPreview($0) },
        onClose: { [weak self] in self?.setRevealed(false) },
        onTextCopy: { [weak self] _ in self?.line.texts.copySelection() },
        onTextPreview: { [weak self] in self?.showTextPreview($0) }, onLinkPreview: { [weak self] in self?.showLinkPreview($0) },
        onCopyAndClose: { [weak self] in self?.copyAndDismissShelf() })
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var historyTimer: Timer?
    private var imageSearch: LibraryImageSearch?

    /// Whether the line is eligible for presentation. A tucked-away panel is
    /// ordered out once its short native fade has completed.
    private var isPresent = false
    /// Whether the line is shown.
    private var isRevealed = false
    private var pointerFocus = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditingMenu.install(onSettings: { [weak self] in self?.showSettings() })
        if startupError != nil { setUpStatusItem(); DispatchQueue.main.async { [weak self] in self?.showStartupFailure() }; return }
        let host = ShelfHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
        panel.searchEditorTarget = { [weak line] in
            guard let line, let shelf = line.searchEditingShelf else { return nil }
            return ShelfSearchFocus(shelf: shelf, request: line.searchFocusRequests[shelf, default: 0])
        }
        panel.contentHeight = line.panelHeight
        panel.onScrollLocation = { [weak self] point in
            guard let self else { return }
            let index = max(0, min(self.line.presentation.shelves.count - 1, Int((self.panel.frame.height - point.y) / Layout.panelHeight)))
            self.line.focusShelf(self.line.presentation.shelves[index], requestFocus: false)
        }
        panel.onScroll = { [weak self] x, y, precise in
            guard let self else { return }
            if self.line.showingTexts {
                let delta = abs(x) > abs(y) ? x : y
                self.line.texts.scroll(delta * (precise ? 1 : 24), width: self.line.viewportWidth)
            } else if self.line.activeShelf == .links { self.line.links.scroll((abs(x) > abs(y) ? x : y) * (precise ? 1 : 24), width: self.line.viewportWidth) }
            else { self.line.scroll(horizontal: x, vertical: y, precise: precise) }
        }
        panel.onKey = { [weak self] event in
            guard let self else { return false }
            let handled = self.keyboard.handle(event)
            if handled { self.pointerFocus = false }
            return handled
        }
        panel.onCommandKey = { [weak self] event in
            guard let self, self.line.keyboardBindings.action(for: event, in: .line) == .commandPalette else { return false }
            self.showCommands(origin: .line); return true
        }
        line.onSettingsRequested = { [weak self] in self?.showSettings() }
        line.onFlushPreview = { [weak self] in
            guard let self else { return true }
            return self.flushPreviewEdits() && (self.libraryController?.flush() ?? true)
        }
        line.onLibraryRequested = { [weak self] in self?.showLibrary() }
        line.onPinToFolderRequested = { [weak self] ids in self?.showPinFolderPicker(ids) }
        line.onNameAndPinRequested = { [weak self] id in self?.showNameAndPin(id) }
        line.onNameAndPinBatchRequested = { [weak self] ids in self?.showNameAndPin(ids) }
        line.onPasteRequested = { [weak self] ids in self?.pasteItems(ids) }
        line.onUploadRequested = { [weak self] id, force in self?.uploadItem(id, forceReupload: force) }
        line.onTagRequested = { [weak self] ids in self?.showTagPicker(ids) }
        line.onImageTextCopyRequested = { [weak self] id in self?.copyImageText(id) }
        line.onCommandsRequested = { [weak self] in self?.showCommands(origin: .line) }
        line.onFocusRequested = { [weak self] in self?.focusLine() }
        line.onExportRequested = { [weak self] in self?.exportSelection() }
        line.onTrashRequested = { [weak self] in self?.trashSelection() }
        line.onImageTrashRequested = { [weak self] in self?.trashImages($0) }
        line.onTextPreviewRequested = { [weak self] in self?.showTextPreview($0) }
        line.onTextTrashRequested = { [weak self] in self?.trashText($0) }
        line.onLinkPreviewRequested = { [weak self] in self?.showLinkPreview($0) }
        line.onLinkItemsVisible = { [weak self] in self?.metadataService?.request($0) }
        let historyTimer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.line.prune() }
        }
        RunLoop.main.add(historyTimer, forMode: .common)
        self.historyTimer = historyTimer
        panel.placeOnScreen()
        updateCapacity()

        if watchesFiles {
            if Inbox.isEnabled { Inbox.apply() }
            startWatcher()
        }
        restoreSettingsOnTermination()

        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }
        refreshTextSources()

        registerShortcut()

        registerCopyShortcut(line.copyLatestShortcut, persist: false)
        registerUploadShortcut(line.uploadLatestShortcut, persist: false)
        registerLibraryShortcut(line.libraryShortcut, persist: false)
        if watchesFiles { registerSearchShortcut(line.globalSearchShortcut, persist: false) }
        setUpStatusItem()
        watchMenuBarClicks()
        setUpAutomaticUpdates()
        if let store = line.library {
            let search = LibraryImageSearch(store: store); imageSearch = search; store.imageSearch = search; search.start()
        }

        line.onImageMarkupRequested = { [weak self] id in self?.showPreview(id); self?.preview?.beginMarkup() }
        Trim.shared.onSaved = { [weak self] _, url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        line.texts.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.itemsChanged() }.store(in: &cancellables)
        line.links.$entries.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.itemsChanged()
            if let session = self?.previewSession, session.shelf == .links { self?.updatePreview(session) }
        }.store(in: &cancellables)
        line.$presentation.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.panel.contentHeight = self.line.panelHeight
            self.panel.placeOnScreen(); self.updateCapacity(); self.itemsChanged()
        }.store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didActivateApplicationNotification,
                       let self, !self.isPasting,
                       let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self.directPaste.recordActivation(app.processIdentifier)
                    }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if watchesFiles && !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appUpdates.stopAutomaticChecks()
        if let updateWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(updateWakeObserver) }
        directPaste.cancel(); imageTextCopy?.cancel(); r2Coordinator.cancelAll()
        imageSearch?.stop()
        _ = preview?.flushEdits(); _ = textPreview?.flushEdits()
        _ = libraryController?.flush(); metadataService?.stop()
        clipboardWatcher.stop()
        textWatcher.stop()
        historyTimer?.invalidate()
        if Inbox.isEnabled { Inbox.restore() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !flushPreviewEdits() || libraryController?.flush() == false { preview?.show(); textPreview?.show(); return .terminateCancel }
        return .terminateNow
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        if watchesFiles { startWatcher() }
    }

    private func setInbox(_ on: Bool) {
        guard watchesFiles else { return }
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off in Settings, and your settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard remains opt in through Settings.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard self?.flushPreviewEdits() ?? true else { return }
                guard self?.libraryController?.flush() ?? true else { return }
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        if visibleCount > 0 {
            wanted = true
            refresh()
        } else if !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.visibleCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }
    private var visibleCount: Int {
        (line.presentation.shelves.contains(.images) ? line.liveCount : 0)
        + (line.presentation.shelves.contains(.texts) ? line.texts.displayEntries.count : 0)
        + (line.presentation.shelves.contains(.links) ? line.links.displayEntries.count : 0)
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        guard line.presentation.shelves.contains(.images) else {
            line.hang(url)
            return
        }
        if !isRevealed && Self.peeksAtNew && !isPasting {
            withPasteTargetForFocusHandoff { presentCapture(url) }
        } else {
            presentCapture(url)
        }
    }

    private func presentCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        let wasRevealed = isRevealed
        comeDown(on: screen)
        guard let id = line.hang(url, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        // The reveal precedes insertion for the capture animation. Include the
        // new first card when this capture opened the line, without replacing
        // the user's selection on a line that was already open.
        if !wasRevealed {
            line.selectFirstShelfItems(line.presentation.shelves)
            if isRevealed && !ownsKeyboardFocus() && !isPasting {
                focusLine()
                // Keep the timed peek until a browsing key is used. Enter or
                // Space then promotes it to the normal keyboard session.
                pointerFocus = true
            }
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard line.presentation.shelves.contains(.images), let index = line.displayItems.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, scrollOffset: line.scrollOffset)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.displayItems[index].thumb?.size ?? CGSize(width: 136, height: 104))
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool, restoreApplication: Bool = true) {
        guard on != isRevealed else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordShelfPresentation(on ? "visibility.open" : "visibility.close", since: start) }
        isRevealed = on
        line.revealed = on
        // Preserve each shelf’s position; a newly hung capture already resets its row.
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if !on {
            pointerFocus = false
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            let hadFocus = panel.isKeyWindow
            panel.keyboardFocusAllowed = false
            if hadFocus {
                panel.resignKey()
                if restoreApplication { previousApplication?.activate(options: []) }
            }
            previousApplication = nil
        }
        panel.setShelfRevealed(on) { [weak self] in
            guard let self, on == self.isRevealed else { return }
            if on { self.updateMousePassThrough(NSEvent.mouseLocation) }
            else { self.panel.orderOut(nil) }
        }
        // Install the hidden-to-open transform before exposing the window;
        // otherwise its first committed frame can flash fully open.
        if on, isPresent { panel.orderFrontRegardless() }
    }

    @objc private func toggle() {
        let start = ProcessInfo.processInfo.systemUptime
        let opening = !isRevealed
        defer { recordShelfPresentation(opening ? "toggle.open" : "toggle.close", since: start) }
        if isRevealed {
            setRevealed(false)
            if visibleCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            withPasteTargetForFocusHandoff {
                keepOpen = true
                wanted = true
                panel.placeOnScreen()
                updateCapacity()
                refresh()
                reveal(pinned: true)
                focusLine(preservePasteTarget: true)
            }
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    static func clickScreenPoint(_ event: NSEvent?) -> NSPoint {
        if let event, let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = Self.clickScreenPoint(event)
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        if !isRevealed && (settingsController?.window?.isVisible == true || libraryController?.window?.isVisible == true) { hotZoneSince = nil; return }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        let pointerRevealAllowed = pointerRevealIsAllowed(inMenuBar: inMenuBar)

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if Self.opensFromMenuBar, let screen = screenUnderPointer, pointerRevealAllowed,
               !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    revealFromPointer(on: screen)
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || line.pressedID != nil || now < peekUntil
            || (panel.isKeyWindow && !pointerFocus) || previewWindow != nil || pinFolderPicker != nil || tagPicker != nil || nameAndPinPicker != nil || commandPalette != nil || shortcutRecorder != nil || ToggleShortcutRecorder.shared.isRecording || operationBusy
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// Dismissing from the top toolbar must not count the same resting pointer
    /// as a new request to steal keyboard focus back from the paste target.
    func pointerRevealIsAllowed(inMenuBar: Bool) -> Bool {
        if !inMenuBar { menuBarSuppressed = false }
        return inMenuBar && !menuBarSuppressed
    }

    /// A deliberate menu-bar dwell supports browsing immediately. Like a new
    /// capture peek, it can retract until the user starts keyboard browsing.
    func revealFromPointer(on screen: NSScreen) {
        withPasteTargetForFocusHandoff {
            if panel.screen != screen { panel.placeOnScreen(screen); updateCapacity() }
            refresh(); reveal(); focusLine(preservePasteTarget: true); pointerFocus = true
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !panel.isShelfTransitioning else { panel.ignoresMouseEvents = true; return }
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto {
            overPhoto = line.scrollableShelfBandContains(flipped)
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func reportShortcutRestoreFailure() {
        let warning = L("A shortcut could not be restored after recording. Choose another combination in Settings.")
        shortcutRestoreWarning = warning; line.notice = warning
        settingsController?.model.shortcutWarning = warning
    }
    private func clearResolvedShortcutWarning() {
        guard shortcutRestoreWarning != nil,
              Shortcut.current == nil || hotKey?.isRegistered == true,
              line.globalSearchShortcut == nil || searchHotKey?.isRegistered == true,
              line.libraryShortcut == nil || libraryHotKey?.isRegistered == true,
              line.copyLatestShortcut == nil || copyHotKey?.isRegistered == true,
              line.uploadLatestShortcut == nil || uploadHotKey?.isRegistered == true else { return }
        if line.notice == shortcutRestoreWarning { line.notice = nil }
        shortcutRestoreWarning = nil; settingsController?.model.shortcutWarning = nil
    }

    // MARK: Shortcut

    private func registerShortcut() {
        defer { clearResolvedShortcutWarning() }
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // The recorder suspends every owned global shortcut, including its
        // current combination, and restores them before this completion runs.
        ToggleShortcutRecorder.shared.record(onRestoreFailure: { [weak self] in self?.reportShortcutRestoreFailure() }) { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
            self.settingsController?.model.refresh()
        }
    }

    private func setSize(_ size: Layout.Size) {
        guard size != line.size else { return }
        line.setSize(size)
        panel.contentHeight = line.panelHeight
        panel.placeOnScreen(panel.screen)
        updateCapacity()
    }

    private func updateCapacity() {
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordShelfPresentation("panel.layout", since: start) }
        if let screen = panel.screen ?? LinePanel.screenUnderPointer() { line.fitShelves(in: screen.visibleFrame.height) }
        if panel.contentHeight != line.panelHeight { panel.contentHeight = line.panelHeight; panel.placeOnScreen(panel.screen) }
        line.setViewportWidth(panel.frame.width)
    }

    // MARK: Menu bar

    private func setUpAutomaticUpdates() {
        guard watchesFiles, appUpdates.isConfigured else { return }
        updateNotifications.start()
        updateNotifications.onResponse = { [weak self] response in
            guard let self else { return }
            self.showUpdateSettings()
            switch response {
            case .show: break
            case .install(let build): self.appUpdates.installAvailableUpdate(expectedBuild: build)
            }
        }
        appUpdates.onAutomaticUpdateAvailable = { [weak self] update, completion in
            guard let self else { completion(false); return }
            self.updateNotifications.announce(update, completion: completion)
        }
        appUpdates.onPublicUpdateAvailable = { [weak self] version, build in
            self?.updateNotifications.announce(version: version, build: build) { _ in }
        }
        appUpdates.$automaticChecksEnabled.sink { [weak self] enabled in
            self?.updateNotifications.setEnabled(enabled)
        }.store(in: &cancellables)
        appUpdates.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateStatusIcon()
        }.store(in: &cancellables)
        updateWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appUpdates.recheckAutomaticUpdatesAfterWake() }
            }
        appUpdates.startAutomaticChecks()
    }

    private func showUpdateSettings() {
        showSettings()
        settingsController?.model.updatesRequest += 1
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The icon fills in while copied images or text are hung, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled || TextClipboardWatcher.isEnabled || LinkHistory.isEnabled
        let summary = StatusSummary(line: line)
        if let symbol = NSImage(systemSymbolName: AppIdentity.statusSymbol + (on ? ".fill" : ""), accessibilityDescription: AppIdentity.name) {
            statusItem?.button?.image = summary.image(symbol: symbol)
        }
        let update = appUpdates.availableVersion != nil ? L("Update available") : nil
        statusItem?.button?.appearsDisabled = summary.count == 0 && update == nil
        statusItem?.button?.contentTintColor = update == nil ? nil : .systemBlue
        statusItem?.button?.toolTip = [AppIdentity.name, summary.description, update].compactMap { $0 }.joined(separator: "\n")
        statusItem?.button?.setAccessibilityLabel([AppIdentity.name, summary.description, update].compactMap { $0 }.joined(separator: ", "))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let identity = NSMenuItem(title: AppIdentity.name, action: nil, keyEquivalent: "")
        identity.isEnabled = false
        menu.addItem(identity)
        menu.addItem(.separator())
        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in self?.toggle() }
        toggleItem.isEnabled = startupError == nil
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)
        let library = ClosureMenuItem(L("Library…")) { [weak self] in self?.showLibrary() }; library.isEnabled = line.library != nil; menu.addItem(library)
        let actions = ClosureMenuItem(L("Actions") + "…  " + line.keyboardBindings.title(.commandPalette)) { [weak self] in self?.showCommands() }
        actions.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        actions.isEnabled = startupError == nil
        menu.addItem(actions)
        let copy = ClosureMenuItem(L("Copy latest image")) { [weak self] in self?.copyLatest() }
        copy.isEnabled = line.newestID != nil
        menu.addItem(copy)
        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher?.folder ?? self.line.historyFiles.inbox)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") { [weak self] in self?.showSettings() })
        if let version = appUpdates.availableVersion, let build = appUpdates.availableBuild {
            let install = ClosureMenuItem(L("Install update…") + " " + version) { [weak self] in
                guard let self else { return }
                self.showUpdateSettings()
                self.appUpdates.installAvailableUpdate(expectedBuild: build)
            }
            install.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: L("Update available"))
            install.isEnabled = watchesFiles && startupError == nil && !appUpdates.busy
            menu.addItem(install)
        }
        let updates = ClosureMenuItem(L("Check for updates…")) { [weak self] in
            guard let self else { return }
            self.showUpdateSettings()
            self.appUpdates.manualCheck()
        }
        updates.isEnabled = watchesFiles && startupError == nil && appUpdates.isConfigured
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(format: L("Quit %@"), AppIdentity.name), key: "q") { NSApp.terminate(nil) })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        guard startupError == nil else { showStartupFailure(); return }
        capturePasteTarget()
        if settingsController == nil {
            let model = SettingsModel(line: line, allowsSystemChanges: watchesFiles, updates: appUpdates, r2: r2Coordinator)
            model.shortcutWarning = shortcutRestoreWarning
            model.onCommands = { [weak self] in self?.showCommands(origin: .application) }
            model.setSize = { [weak self] in self?.setSize($0) }
            model.setImages = { [weak self] in self?.setClipboard($0) }
            model.setTexts = { [weak self] on in
                TextClipboardWatcher.isEnabled = on
                self?.refreshTextSources()
                self?.updateStatusIcon()
            }
            model.setLinks = { [weak self] on in LinkHistory.isEnabled = on; self?.refreshTextSources(); self?.updateStatusIcon() }
            model.setMetadata = { [weak self] on in LinkMetadataService.isEnabled = on; if !on { self?.metadataService?.stop() } else { self?.metadataService?.request(self?.line.links.entries.map(\.id) ?? []) } }
            model.setLibraryShortcut = { [weak self] in self?.registerLibraryShortcut($0) }
            model.recordLibraryShortcut = { [weak self] in self?.recordLibraryShortcut() }
            model.setSearchShortcut = { [weak self] in self?.registerSearchShortcut($0) }
            model.recordSearchShortcut = { [weak self] in self?.recordSearchShortcut() }
            model.setUploadShortcut = { [weak self] in self?.registerUploadShortcut($0) }
            model.recordUploadShortcut = { [weak self] in self?.recordUploadShortcut() }
            model.requestPastePermission = { [weak self] in self?.showPastePermission() }
            model.recordContextShortcut = { [weak self] in self?.recordContextShortcut($0) }
            model.openLibrary = { [weak self] in self?.showLibrary() }
            model.setScreenshots = { [weak self] in self?.setInbox($0) }
            model.refreshVisibility = { [weak self] in self?.refresh() }
            model.addFolder = { [weak self] in self?.chooseExtraFolder() }
            model.removeFolder = { [weak self] folder in
                Self.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                if self?.watchesFiles == true { self?.startWatcher() }
            }
            model.changeToggleShortcut = { [weak self] in self?.changeShortcut() }
            model.setCopyShortcut = { [weak self] in self?.registerCopyShortcut($0) }
            model.recordCopyShortcut = { [weak self] in self?.recordShortcut() }
            model.changeLogin = { Self.toggleLaunchAtLogin() }
            model.clearHistory = { [weak self] kind in self?.confirmClearHistory(kind: kind) }
            model.reopenForLanguage = { [weak self] in
                guard let self, self.flushPreviewEdits(), self.libraryController?.flush() ?? true else { return }
                do { try LanguagePreferences.reopen() } catch { self.line.notice = L("The app could not reopen. Quit and open it to apply the language.") }
            }
            settingsController = SettingsWindowController(model: model)
            settingsController?.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
        }
        if isRevealed { setRevealed(false, restoreApplication: false) }
        settingsController?.present()
    }
    private func showStartupFailure() {
        guard let startupError else { return }
        let alert = NSAlert(); alert.messageText = startupError
        alert.addButton(withTitle: L("Close")); alert.addButton(withTitle: L("Open data folder"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Inbox.folder) }
    }
    private func refreshTextSources() {
        textWatcher.skipCurrent()
        if TextClipboardWatcher.isEnabled || LinkHistory.isEnabled { textWatcher.start() } else { textWatcher.stop() }
    }
    func receiveCopiedText(_ text: String) { _ = line.texts.add(text) }
    func showLibrary() {
        guard let store = line.library, flushPreviewEdits() else { return }
        capturePasteTarget()
        if libraryController == nil {
            let controller = LibraryWindowController(store: store, line: line, copyPasteboard: isolatedCopyBoard)
            controller.onSettings = { [weak self] in self?.showSettings() }
            controller.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
            controller.onBeforePreviewMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
            controller.onRefreshLink = { [weak self] in self?.metadataService?.request([$0], force: true) }
            controller.model.onVisibleLinks = { [weak self] in self?.metadataService?.request($0) }
            controller.model.onPasteRequested = { [weak self] in self?.pasteItems($0) }
            controller.model.onUploadRequested = { [weak self] id, force in self?.uploadItem(id, forceReupload: force) }
            controller.model.onImageTextCopyRequested = { [weak self] in self?.copyImageText($0) }
            controller.model.onCommandsRequested = { [weak self] in self?.showCommands() }
            libraryController = controller
        }
        closePreview(); if isRevealed { setRevealed(false, restoreApplication: false) }
        libraryController?.present()
    }
    private func recordContextShortcut(_ action: KeyboardAction) {
        shortcutRecorder?.window.close()
        let recorder = ShortcutRecorder(allowPlain: true); shortcutRecorder = recorder
        recorder.onRestoreFailure = { [weak self] in self?.reportShortcutRestoreFailure() }
        recorder.window.title = action.title
        recorder.onFinish = { [weak self] value in
            guard let self else { return }; self.shortcutRecorder = nil
            if let value {
                do { try self.line.keyboardBindings.set([value], for: action); self.line.notice = nil }
                catch { self.line.notice = error.localizedDescription }
            }
            self.line.objectWillChange.send(); self.settingsController?.model.refresh()
        }
        recorder.show()
    }

    private func confirmClearHistory(kind: LibraryKind? = nil) {
        guard flushPreviewEdits(), libraryController?.flush() ?? true, let store = line.library else { return }
        let snapshot: UnsavedHistorySnapshot
        do { snapshot = try store.unsavedHistorySnapshot(kind: kind) }
        catch { NSAlert(error: error).runModal(); return }
        let alert = NSAlert()
        alert.messageText = L("Clear unsaved copies?")
        alert.informativeText = String(format: L("%d unsaved copies will move to recoverable Library Trash. Pinned items, saved items, folders, tags and original files are kept."), snapshot.ids.count)
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.isEnabled = !snapshot.ids.isEmpty
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.clearUnsavedHistory(snapshot)
                if let session = previewSession { updatePreview(session) }
                settingsController?.model.refresh()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    static var updatesURL: URL {
        // Release notes only: official binaries do not contain this fork’s features.
        URL(string: "https://github.com/alejandrobujan/tendedero/releases")!
    }

    private func focusLine(preservePasteTarget: Bool = false) {
        guard isRevealed else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordShelfPresentation("panel.focus", since: start) }
        pointerFocus = false
        if !isPasting, !preservePasteTarget, !ownsKeyboardFocus() {
            capturePasteTarget()
        }
        panel.keyboardFocusAllowed = true
        panel.contentHeight = line.panelHeight; panel.placeOnScreen(panel.screen)
        panel.makeKeyAndOrderFront(nil)
        if line.searchEditingShelf == nil { panel.makeFirstResponder(nil) }
    }

    func showPreview(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id }) else { return }
        if item.isRecording { line.quickLook(id); return }
        showShelfPreview(.images, id: id)
    }
    func showTextPreview(_ id: UUID) { showShelfPreview(.texts, id: id) }
    func showLinkPreview(_ id: UUID) { showShelfPreview(.links, id: id) }

    @discardableResult private func flushPreviewEdits() -> Bool {
        (preview?.flushEdits() ?? true) && (textPreview?.flushEdits() ?? true)
    }
    private func wireImageMarkup(_ image: ImagePreview, id: UUID) {
        guard let store = line.library, let record = try? store.item(id), let source = record.markupSourceURL else { return }
        image.configureMarkup(document: record.imageMarkup ?? ImageMarkupDocument(), sourceURL: source)
        image.onSaveMarkup = { [weak self, weak image, weak store] document in
            guard let self, let image, let store else { return false }
            do {
                let saved = try store.saveImageMarkup(id, document: document)
                if let source = saved.markupSourceURL, let rendered = saved.fileURL { image.updateMarkupSource(source, renderedURL: rendered) }
                return true
            } catch { self.line.notice = error.localizedDescription; return false }
        }
    }

    private var currentPreviewWindow: ActionPreviewPanel? {
        previewWindow
    }
    private func showShelfPreview(_ shelf: Shelf, id: UUID) {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        capturePasteTarget()
        libraryController?.dismissPreviews()
        let session = ShelfPreviewSession(line: line, shelf: shelf, id: id)
        guard installPreviewContent(shelf, id: id, session: session, window: currentPreviewWindow) else { return }
        session.selectCurrent(); showCurrentPreview()
    }
    /// Install the next renderer without closing or replacing its native window.
    /// Construction validates the target before retiring the old controller.
    private func installPreviewContent(_ shelf: Shelf, id: UUID, session: ShelfPreviewSession, window: ActionPreviewPanel?) -> Bool {
        let image: ImagePreview?, text: TextPreview?, link: LinkPreview?
        let controls: PreviewControls
        switch shelf {
        case .images:
            guard let item = line.items.first(where: { $0.id == id && !$0.isRecording }),
                  let value = ImagePreview(url: item.url, keyboardBindings: line.keyboardBindings, window: window) else { return false }
            image = value; text = nil; link = nil; controls = value.controls
            wireImageMarkup(value, id: id)
            value.onKey = { [weak self] in self?.handlePreviewKey($0, session: session) ?? false }
            value.onClose = { [weak self] in self?.previewDidClose(session) }
        case .texts:
            guard let entry = line.texts.entries.first(where: { $0.id == id }) else { return false }
            let value = TextPreview(text: entry.text, copyPasteboard: isolatedCopyBoard, keyboardBindings: line.keyboardBindings, window: window)
            image = nil; text = value; link = nil; controls = value.controls
            value.onSave = { session.saveText($0) }
            value.onKey = { [weak self] in self?.handlePreviewKey($0, session: session) ?? false }
            value.onClose = { [weak self] in self?.previewDidClose(session) }
        case .links:
            guard let record = line.links.entries.first(where: { $0.id == id }) else { return false }
            let value = LinkPreview(record: record, keyboardBindings: line.keyboardBindings, window: window)
            image = nil; text = nil; link = value; controls = value.controls
            value.onKey = { [weak self] in self?.handlePreviewKey($0, session: session) ?? false }
            value.onClose = { [weak self] in self?.previewDidClose(session) }
        }
        preview?.scroll.endPan()
        preview = image; textPreview = text; linkPreview = link
        emptyPreview = nil
        previewWindow = (image?.window ?? text?.window ?? link?.window) as? ActionPreviewPanel
        previewWindow?.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
        previewSession = session; previewDisplayedID = id
        wirePreviewControls(controls, session: session)
        return true
    }
    private func showCurrentPreview() {
        preview?.show(); textPreview?.show(); linkPreview?.show()
        if emptyPreview != nil { previewWindow?.makeKeyAndOrderFront(nil) }
    }
    private func previewDidClose(_ session: ShelfPreviewSession) {
        guard previewSession === session else { return }
        preview = nil; textPreview = nil; linkPreview = nil; previewSession = nil; previewDisplayedID = nil
        emptyPreview = nil; previewWindow = nil
        if isRevealed { focusLine(preservePasteTarget: true) }
    }

    private func wirePreviewControls(_ controls: PreviewControls, session: ShelfPreviewSession) {
        controls.onCommands = { [weak self] in self?.showCommands(origin: .shelfPreview) }
        controls.update(position: session.position, pinned: session.pinned, uploaded: session.uploadedURL != nil)
        controls.onMove = { [weak self] in self?.movePreview(session, delta: $0) }
        controls.onCopy = { [weak self] in self?.copyPreview(session) }
        controls.onUpload = { [weak self] in self?.uploadPreview(session) }
        controls.onPin = { [weak self] in self?.pinPreview(session) }
    }
    private func movePreview(_ session: ShelfPreviewSession, delta: Int) {
        guard flushPreviewEdits() else { return }
        guard session.move(delta) else { return }
        updatePreview(session)
    }
    private func movePreviewShelf(_ session: ShelfPreviewSession, delta: Int) {
        guard flushPreviewEdits() else { return }
        let window = currentPreviewWindow
        guard session.moveShelf(delta, canPresent: { [self] shelf, id in
            installPreviewContent(shelf, id: id, session: session, window: window)
        }) else { return }
        updatePreview(session); showCurrentPreview()
    }
    private func movePreviewToBoundary(_ session: ShelfPreviewSession, last: Bool) {
        guard flushPreviewEdits(), session.moveToBoundary(last: last) else { return }
        updatePreview(session)
    }
    private func movePreviewPage(_ session: ShelfPreviewSession, delta: Int) {
        guard flushPreviewEdits(), session.movePage(delta) else { return }
        updatePreview(session)
    }
    @discardableResult private func copyPreview(_ session: ShelfPreviewSession) -> Bool {
        guard emptyPreview == nil, session.hasCurrentItem || actionablePreviewID == session.currentID, flushPreviewEdits(),
              session.copy() else { return false }
        if session.shelf == .links, line.links.copiedIDs.contains(session.currentID) { linkPreview?.flashCopied() }
        if session.shelf == .texts, line.texts.copiedIDs.contains(session.currentID) { textPreview?.flashCopied() }
        else if session.shelf == .images, line.copiedID == session.currentID {
            let copiedID = session.currentID
            preview?.controls.position.stringValue = L("Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard self?.previewSession === session, session.shelf == .images,
                      session.currentID == copiedID, self?.line.copiedID != copiedID else { return }
                self?.preview?.controls.update(position: session.position, pinned: session.pinned, uploaded: session.uploadedURL != nil)
            }
        }
        return true
    }
    private func uploadPreview(_ session: ShelfPreviewSession) {
        guard emptyPreview == nil, flushPreviewEdits(), let id = actionablePreviewID else { return }
        uploadItem(id)
    }
    private func pinPreview(_ session: ShelfPreviewSession) {
        guard emptyPreview == nil, session.hasCurrentItem || actionablePreviewID == session.currentID, flushPreviewEdits() else { return }
        _ = session.togglePin()
        updatePreview(session)
    }
    private func removePreviewItem(_ session: ShelfPreviewSession) {
        guard flushPreviewEdits(), session.removeCurrent() else { return }
        updatePreview(session)
    }
    private func undoPreviewRemoval(_ session: ShelfPreviewSession) {
        guard flushPreviewEdits(), session.undoRemoval() else { return }
        updatePreview(session)
    }
    private func showEmptyPreview(_ session: ShelfPreviewSession, unavailable: Bool = false) {
        let message = unavailable ? L("File could not be read or safely saved") : L("No matching items")
        if let emptyPreview { emptyPreview.message.stringValue = message; return }
        guard let window = previewWindow else { return }
        let empty = EmptyShelfPreview(window: window, keyboardBindings: line.keyboardBindings, message: message)
        empty.onKey = { [weak self] in self?.handlePreviewKey($0, session: session) ?? false }
        empty.onUndo = { [weak self] in self?.undoPreviewRemoval(session) }
        empty.onClose = { [weak self] in self?.previewDidClose(session) }
        preview?.scroll.endPan()
        preview = nil; textPreview = nil; linkPreview = nil; previewDisplayedID = nil; emptyPreview = empty
        showCurrentPreview()
    }
    private func showPinFolderPicker(_ ids: [UUID]) {
        guard flushPreviewEdits(), let store = line.library, !ids.isEmpty else { return }
        capturePasteTarget()
        if let pinFolderPicker { pinFolderPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = textPreview?.window ?? linkPreview?.window ?? preview?.window ?? panel
            let picker = try PinFolderPicker(store: store, ids: ids); pinFolderPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
            picker.onClose = { [weak self, weak parent] in
                guard let self else { return }; self.pinFolderPicker = nil
                if let session = self.previewSession { self.updatePreview(session) }
                if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
            }
            picker.show(relativeTo: parent)
        } catch { line.notice = error.localizedDescription }
    }
    private func updatePreview(_ session: ShelfPreviewSession) {
        guard session.hasCurrentItem else { showEmptyPreview(session); return }
        let needsRenderer: Bool
        switch session.shelf { case .images: needsRenderer = preview == nil; case .texts: needsRenderer = textPreview == nil; case .links: needsRenderer = linkPreview == nil }
        if needsRenderer {
            if installPreviewContent(session.shelf, id: session.currentID, session: session, window: previewWindow) { showCurrentPreview() }
            else { showEmptyPreview(session, unavailable: true) }
            return
        }
        if session.shelf == .texts {
            guard let text = session.text else { closePreview(); return }
            // Pinning the current note keeps the editor and its caret intact.
            if previewDisplayedID != session.currentID {
                textPreview?.replaceText(text)
            }
            textPreview?.controls.update(position: session.position, pinned: session.pinned, uploaded: session.uploadedURL != nil)
        } else if session.shelf == .links {
            guard let record = session.linkRecord else { closePreview(); return }
            linkPreview?.replace(record); linkPreview?.controls.update(position: session.position, pinned: session.pinned, uploaded: session.uploadedURL != nil)
        } else {
            guard let url = session.url else { closePreview(); return }
            // Moving a favorite to managed storage keeps the current zoom and pan.
            if previewDisplayedID != session.currentID, preview?.replaceImage(url: url) != true {
                showEmptyPreview(session, unavailable: true); return
            }
            if previewDisplayedID != session.currentID, let preview { wireImageMarkup(preview, id: session.currentID) }
            if let record = try? line.library?.item(session.currentID), let base = record.markupSourceURL, let rendered = record.fileURL {
                preview?.updateMarkupSource(base, renderedURL: rendered)
            }
            preview?.controls.update(position: session.position, pinned: session.pinned, uploaded: session.uploadedURL != nil)
        }
        previewDisplayedID = session.currentID
    }
    private func closePreview() { if flushPreviewEdits() { previewWindow?.close() } }
    /// Editing can remove a note from the search results while its saved
    /// content remains in this preview. Actions use the displayed live record.
    private var actionablePreviewID: UUID? {
        guard emptyPreview == nil, let session = previewSession,
              previewDisplayedID == session.currentID,
              let record = try? line.library?.item(session.currentID), record.deletedAt == nil,
              record.kind == session.shelf.libraryKind else { return nil }
        return record.id
    }
    private func handlePreviewKey(_ event: NSEvent, session: ShelfPreviewSession) -> Bool {
        let context: KeyboardContext = session.shelf == .texts ? .textPreview : session.shelf == .links ? .linkPreview : .imagePreview
        guard let action = line.keyboardBindings.action(for: event, in: context) else { return false }
        switch action {
        case .paste: if let id = actionablePreviewID { pasteItems([id]) }
        case .upload: uploadPreview(session)
        case .finishEditing:
            if line.keyboardBindings.matches(.paste, event: event), let id = actionablePreviewID { pasteItems([id]) }
            else { return false }
        case .copyImageText: if let id = actionablePreviewID, session.shelf == .images { copyImageText(id) }
        case .commandPalette: showCommands(origin: .shelfPreview)
        case .tag: if let id = actionablePreviewID { showTagPicker([id]) }
        case .removeFromLine: removePreviewItem(session)
        case .undoRemoveFromLine: undoPreviewRemoval(session)
        case .copy:
            if copyPreview(session), (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                dismissAfterCopy()
            }
        case .pin: pinPreview(session)
        case .pinToFolder: if let id = actionablePreviewID { showPinFolderPicker([id]) }
        case .nameAndPin: if let id = actionablePreviewID { showNameAndPin(id) }
        case .pinnedOnly:
            guard flushPreviewEdits() else { return true }
            _ = session.toggleFavorites(); updatePreview(session)
        case .previous: movePreview(session, delta: -1)
        case .next: movePreview(session, delta: 1)
        case .first: movePreviewToBoundary(session, last: false)
        case .last: movePreviewToBoundary(session, last: true)
        case .previousPage: movePreviewPage(session, delta: -1)
        case .nextPage: movePreviewPage(session, delta: 1)
        case .up: movePreviewShelf(session, delta: -1)
        case .down: movePreviewShelf(session, delta: 1)
        case .open: linkPreview?.openCurrent()
        default: return false
        }
        return true
    }

    private func trashText(_ id: UUID) {
        operationBusy = true; defer { operationBusy = false }
        let alert = NSAlert(); alert.messageText = L("Move this text to recoverable Trash?")
        alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { line.texts.trash([id]) }
        focusLine()
    }

    /// Shared by every browsing surface before it takes key focus. A floating
    /// panel can own the keyboard while the workspace still names the external
    /// app, so workspace PID/previousApplication cannot identify this boundary.
    func capturePasteTarget() {
        guard pasteFocusHandoffDepth == 0 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordShelfPresentation("paste-target.capture", since: start) }
        directPaste.cancel(); isPasting = false
        let ownFocus = ownsKeyboardFocus()
        DirectPasteDiagnostics.log.debug("Capture boundary ownsKeyboard=\(ownFocus)")
        guard !ownFocus else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        directPaste.captureTarget()
    }

    /// Capture before ordering any window, then keep that exact field through
    /// the synchronous presentation. Web editors can blur before AppKit sets
    /// our keyWindow, so a nested focus request must not recapture that blur.
    /// A later external entry runs outside this scope and captures afresh.
    func withPasteTargetForFocusHandoff(_ present: () -> Void) {
        capturePasteTarget()
        pasteFocusHandoffDepth += 1
        defer { pasteFocusHandoffDepth -= 1 }
        present()
    }
    func openShelfSearch() {
        guard line.shelfSearch != nil, flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        withPasteTargetForFocusHandoff {
            closePreview(); libraryController?.dismissForPaste()
            if !isRevealed {
                keepOpen = true; wanted = true; panel.placeOnScreen(); updateCapacity(); refresh(); reveal(pinned: true)
            }
            focusLine(preservePasteTarget: true); line.beginShelfSearch()
        }
    }
    private func registerSearchShortcut(_ value: KeyShortcut?, persist: Bool = true) {
        defer { clearResolvedShortcutWarning() }
        guard let value else {
            searchHotKey?.invalidate(); searchHotKey = nil
            if persist { line.saveGlobalSearchShortcut(nil) }; return
        }
        guard value.isValid else { return }
        if searchHotKey?.isRegistered == true && value == line.globalSearchShortcut { return }
        let replacement = HotKey(keyCode: value.keyCode, modifiers: value.modifiers) { [weak self] in self?.openShelfSearch() }
        guard replacement.isRegistered else { line.notice = L("Shortcut unavailable; the previous shortcut is kept"); return }
        searchHotKey?.invalidate(); searchHotKey = replacement
        if persist { line.saveGlobalSearchShortcut(value) }
        settingsController?.model.refresh()
    }
    private func recordSearchShortcut() {
        shortcutRecorder?.window.close(); let recorder = ShortcutRecorder(); shortcutRecorder = recorder
        recorder.onRestoreFailure = { [weak self] in self?.reportShortcutRestoreFailure() }
        recorder.window.title = L("Search shelves from other apps")
        recorder.onFinish = { [weak self] value in
            self?.shortcutRecorder = nil
            if let value { self?.registerSearchShortcut(value) }
        }
        recorder.show()
    }
    private func showPastePermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func reportActionStatus(_ message: String) {
        line.notice = message
        libraryController?.reportActionStatus(message)
        preview?.controls.position.stringValue = message
        textPreview?.controls.position.stringValue = message
        linkPreview?.controls.position.stringValue = message
    }
    private func pasteItems(_ ids: [UUID]) {
        guard !ids.isEmpty, let store = line.library, flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        do {
            let records = try store.records(ids)
            guard records.allSatisfy({ $0.deletedAt == nil }) else { return }
            let items = try LibraryTransfer.pasteboardItems(records)
            isPasting = true
            directPaste.paste(items: items, dismiss: { [weak self] in
                self?.dismissBrowsingForPaste()
            }, completion: { [weak self] result in
                guard let self else { return }; self.isPasting = false
                switch result {
                case .pasted: self.reportActionStatus(L("Pasted"))
                case .permissionRequired:
                    self.reportActionStatus(L("Accessibility permission is needed to paste into another app."))
                    let alert = NSAlert()
                    if #available(macOS 27, *) {
                        alert.messageText = L("Allow this app in Privacy & Security → Device Control and Data Access to paste into another app.")
                        alert.addButton(withTitle: L("Open Device Control and Data Access"))
                    } else {
                        alert.messageText = L("Accessibility permission is needed to paste into another app.")
                        alert.addButton(withTitle: L("Open Accessibility Settings"))
                    }
                    alert.addButton(withTitle: L("Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn { self.showPastePermission() }
                case .noTarget: self.reportActionStatus(L("Select a text field in another app, then reopen the shelves."))
                case .focusChanged: self.reportActionStatus(L("The target text field changed. Reopen the shelves and try again."))
                case .copyFailed, .pasteFailed: self.reportActionStatus(L("Could not paste into the target app."))
                }
            })
        } catch { reportActionStatus(error.localizedDescription) }
    }
    private func copyAndDismissShelf() {
        guard line.copySelection() else { return }
        dismissAfterCopy()
    }
    private func dismissAfterCopy() {
        let returnApplication = previousApplication
        let hadFocus = panel?.isKeyWindow == true || previewWindow?.isKeyWindow == true
        menuBarSuppressed = true; hotZoneSince = nil
        // Hide the shelf before closing its child: previewDidClose must not
        // re-key it. Restore the saved application after both panels let go.
        setRevealed(false, restoreApplication: false)
        panel?.orderOut(nil)
        previewWindow?.close()
        if hadFocus { returnApplication?.activate(options: []) }
    }
    func dismissBrowsingForPaste() {
        menuBarSuppressed = true; hotZoneSince = nil
        // The coordinator alone restores its captured destination. The older
        // shelf opener may belong to a different app after own-view handoffs.
        if isRevealed { setRevealed(false, restoreApplication: false) }
        // Do not let a closing child palette re-key the animating shelf parent.
        panel?.orderOut(nil)
        closePreview(); libraryController?.dismissForPaste()
        commandPalette?.window.close(); pinFolderPicker?.window.close(); tagPicker?.window.close(); nameAndPinPicker?.window.close()
    }
    private func copyImageText(_ id: UUID) {
        guard let record = try? line.library?.item(id), record.kind == .image, record.deletedAt == nil else { return }
        reportActionStatus(L("Reading image text…"))
        imageTextCopy?.copy(id) { [weak self] result in
            switch result {
            case .copied: self?.reportActionStatus(L("Image text copied"))
            case .noText: self?.reportActionStatus(L("No text found in image"))
            case .unavailable: self?.reportActionStatus(L("Image text unavailable"))
            case .failed: self?.reportActionStatus(L("Could not copy image text"))
            }
        }
    }
    private func showTagPicker(_ ids: [UUID]) {
        guard !ids.isEmpty, let store = line.library, flushPreviewEdits() else { return }
        capturePasteTarget()
        if let tagPicker { tagPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = previewWindow ?? panel
            let picker = try TagPicker(store: store, ids: ids); tagPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
            picker.onClose = { [weak self, weak parent] in
                self?.tagPicker = nil
                if let self, let session = self.previewSession { self.updatePreview(session) }
                if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
            }
            picker.show(relativeTo: parent)
        } catch { line.notice = error.localizedDescription }
    }
    func showNameAndPin(_ id: UUID) { showNameAndPin([id]) }
    func showNameAndPin(_ ids: [UUID]) {
        guard !ids.isEmpty, let store = line.library, flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        capturePasteTarget()
        if let nameAndPinPicker { nameAndPinPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = previewWindow ?? panel
            let picker = try NameAndPinPicker(store: store, ids: ids); nameAndPinPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
            if ids.count > 1, previewSession == nil {
                let shelf = line.activeShelf
                picker.onAdvance = { [weak self] id in self?.line.focusNameAndPinTarget(id, on: shelf) }
                line.focusNameAndPinTarget(picker.id, on: shelf)
            }
            picker.onClose = { [weak self, weak parent] in
                guard let self else { return }; self.nameAndPinPicker = nil
                if let session = self.previewSession { self.updatePreview(session) }
                if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
            }
            picker.show(relativeTo: parent)
        } catch { line.notice = error.localizedDescription }
    }
    private struct ActionBarSnapshot {
        let origin: ActionBarCatalog.Origin
        let ids: [UUID]
        let parent: NSWindow?
        let focusedID: UUID?
        let shelf: Shelf
        let libraryScope: LibraryQuery.Scope?
        var previewID: UUID? { focusedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first }
        var singleID: UUID? { ids.count == 1 ? ids.first : nil }
        var inLibrary: Bool { origin == .library || origin == .libraryPreview }
        var inPreview: Bool { origin == .shelfPreview || origin == .libraryPreview }
    }

    /// Snapshot the invoking surface before the child panel owns keyboard focus.
    /// Its actions keep these IDs even if a background capture reorders the shelf.
    func showCommands(origin requestedOrigin: ActionBarCatalog.Origin? = nil) {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        capturePasteTarget()
        if let commandPalette { commandPalette.window.makeKeyAndOrderFront(nil); commandPalette.window.makeFirstResponder(commandPalette.searchField); return }
        let settingsKey = settingsController?.window?.isKeyWindow == true
        let libraryPreviewKey = libraryController?.previewWindow?.isKeyWindow == true
        let libraryKey = libraryController?.window?.isKeyWindow == true
        let shelfPreviewKey = previewWindow?.isKeyWindow == true || (previewWindow?.isVisible == true && !settingsKey && !libraryKey && !libraryPreviewKey)
        let inferredOrigin: ActionBarCatalog.Origin = libraryPreviewKey ? .libraryPreview : libraryKey ? .library : shelfPreviewKey ? .shelfPreview : settingsKey || !isRevealed ? .application : .line
        let origin = requestedOrigin ?? inferredOrigin
        let ids: [UUID]
        let parent: NSWindow?
        switch origin {
        case .libraryPreview: ids = libraryController?.previewCurrentID.map { [$0] } ?? []; parent = libraryController?.previewWindow
        case .library: ids = libraryController?.model.actionIDs ?? []; parent = libraryController?.window
        case .shelfPreview: ids = actionablePreviewID.map { [$0] } ?? []; parent = previewWindow
        case .line: ids = line.activeActionIDs; parent = panel
        case .application: ids = []; parent = settingsKey ? settingsController?.window : nil
        }
        let focusedID: UUID?
        switch origin {
        case .libraryPreview: focusedID = libraryController?.previewCurrentID
        case .library: focusedID = libraryController?.model.focusedID
        case .shelfPreview: focusedID = actionablePreviewID
        case .line: focusedID = line.activeShelf == .images ? line.focusedID : line.activeShelf == .texts ? line.texts.focusedID : line.links.focusedID
        case .application: focusedID = nil
        }
        let snapshot = ActionBarSnapshot(origin: origin, ids: ids, parent: parent, focusedID: focusedID,
            shelf: line.activeShelf, libraryScope: libraryController?.model.query.scope)
        let entries = ActionBarCatalog.entries(context: actionBarContext(snapshot), bindings: line.keyboardBindings)
        if let shelf = line.searchEditingShelf {
            line.finishShelfSearchEditing(shelf, selectFirst: false)
            panel.makeFirstResponder(nil)
        }
        let palette = CommandPalette(commands: entries.map(\.command)) { [weak self] id in
            guard let entry = entries.first(where: { $0.command.id == id }), entry.command.isEnabled else { return }
            self?.performActionBar(entry.action, snapshot: snapshot)
        }
        palette.onSearchContents = { [weak self] in self?.searchContents(from: snapshot) }
        palette.window.onBeforeMouseKeyFocus = { [weak self] in self?.capturePasteTarget() }
        commandPalette = palette
        palette.onClose = { [weak self, weak parent, weak palette] in
            self?.commandPalette = nil
            if palette?.shouldRestoreParentFocus == true, parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
        }
        palette.show(relativeTo: parent)
    }

    private func actionBarContext(_ snapshot: ActionBarSnapshot) -> ActionBarCatalog.Context {
        var value = ActionBarCatalog.Context()
        value.origin = snapshot.origin; value.selectedCount = snapshot.ids.count
        let records = (try? line.library?.records(snapshot.ids)) ?? []
        let record = records.count == 1 ? records.first : nil
        value.kind = record?.kind
        value.uploadedURL = record?.uploadedURL
        value.hasFile = record?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        value.isRecording = record?.fileURL.map(isRecordingFile) ?? false
        value.isDeleted = !records.isEmpty && records.allSatisfy { $0.deletedAt != nil }
        value.allPinned = !records.isEmpty && records.allSatisfy(\.favorite)
        value.hasLatestImage = line.newestID != nil
        value.hasAnyItem = !line.items.isEmpty || !line.texts.entries.isEmpty || !line.links.entries.isEmpty
            || ((try? line.library?.query(LibraryQuery(scope: .recent, sort: .newest), limit: 1).isEmpty == false) ?? false)
        value.globalToggleHint = Shortcut.current?.display ?? ""; value.copyLatestHint = line.copyLatestShortcut?.title ?? ""
        value.uploadLatestHint = line.uploadLatestShortcut?.title ?? ""
        value.canUndoShelfRemoval = line.library?.canUndoShelfRemoval == true
        value.canUndoLibraryTrash = line.library?.canUndoTrash == true
        value.activeFavorites = snapshot.inLibrary ? libraryController?.model.showingPinnedOnly == true : line.activeFavoritesOnly
        value.visibleShelves = Set(line.presentation.shelves)
        value.lineRevealed = isRevealed; value.libraryAvailable = line.library != nil
        value.canCheckUpdates = watchesFiles && startupError == nil && appUpdates.isConfigured && !appUpdates.busy
        value.canInstallUpdate = watchesFiles && startupError == nil && appUpdates.availableVersion != nil && !appUpdates.busy
        switch snapshot.origin {
        case .library, .libraryPreview: value.hasItems = libraryController?.model.ids.isEmpty == false
        case .shelfPreview: value.hasItems = previewSession?.ids.isEmpty == false
        case .line:
            value.hasItems = line.activeShelf == .images ? !line.displayItems.isEmpty : line.activeShelf == .texts ? !line.texts.displayEntries.isEmpty : !line.links.displayEntries.isEmpty
        case .application: break
        }
        let image = snapshot.origin == .libraryPreview ? libraryController?.previewImage : snapshot.origin == .shelfPreview ? preview : nil
        value.isMarkupEditing = image?.isMarkupEditing == true
        value.annotationSelected = image?.canvas.selectedID != nil
        value.canUndoMarkup = image?.canvas.canUndo == true; value.canRedoMarkup = image?.canvas.canRedo == true
        value.hasAnnotations = image?.document.elements.isEmpty == false
        value.isTextEditing = snapshot.origin == .libraryPreview ? libraryController?.previewTextIsEditing == true : snapshot.origin == .shelfPreview && textPreview?.isEditing == true
        if let id = snapshot.singleID {
            value.inInbox = line.items.contains { $0.id == id } && line.isInInbox(id)
            value.canTakeDownLeft = snapshot.origin == .line && !line.neighbours(of: id, toTheLeft: true).isEmpty
            value.canTakeDownRight = snapshot.origin == .line && !line.neighbours(of: id, toTheLeft: false).isEmpty
            value.itemFolders = (try? line.library?.collections(for: id)) ?? []
            value.itemTags = (try? line.library?.tags(for: id)) ?? []
        }
        value.collections = (try? line.library?.collections()) ?? []
        value.tags = (try? line.library?.tags()) ?? []
        if let controller = libraryController {
            let model = controller.model
            value.libraryScope = model.query.scope; value.libraryKind = model.query.kind
            value.libraryListMode = model.listMode; value.libraryInspectorVisible = model.inspectorVisible
            value.librarySort = model.query.sort; value.librarySearchMode = model.query.searchMode
            value.libraryDays = model.query.days; value.hasLibraryFilters = model.query.hasFilters
            value.librarySidebarVisible = controller.splitController.splitViewItems.first?.isCollapsed == false
        }
        return value
    }

    private func searchContents(from snapshot: ActionBarSnapshot) {
        if snapshot.inLibrary {
            guard libraryController?.flush() ?? true else { return }
            actionBarLibrary(from: snapshot)?.model.onSearchFocus?()
        } else { openShelfSearch() }
    }

    private func performActionBar(_ action: ActionBarAction, snapshot: ActionBarSnapshot) {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        switch action {
        case let .keyboard(action): performActionBarKeyboard(action, snapshot: snapshot)
        case let .menu(action): performActionBarMenu(action, snapshot: snapshot)
        case let .openFolder(id):
            actionBarLibrary(from: snapshot)?.model.changeScope(.collection(id))
        case let .openTag(id):
            actionBarLibrary(from: snapshot)?.model.changeScope(.tag(id))
        case let .assignFolder(folder), let .moveToFolder(folder):
            var source: UUID?
            if case .moveToFolder = action, case let .collection(id) = snapshot.libraryScope { source = id }
            do { try line.library?.assign(snapshot.ids, to: folder, movingFrom: source) } catch { reportActionStatus(error.localizedDescription) }
        case let .unassignFolder(folder):
            guard let id = snapshot.singleID else { return }
            do { try line.library?.unassign(id, from: folder) } catch { reportActionStatus(error.localizedDescription) }
        case let .removeItemTag(tag):
            guard let id = snapshot.singleID else { return }
            do { try line.library?.removeTag(tag, from: id) } catch { reportActionStatus(error.localizedDescription) }
        }
    }

    private func showActionBarPreview(_ snapshot: ActionBarSnapshot) {
        guard let id = snapshot.previewID else { return }
        if snapshot.inLibrary { libraryController?.model.onPreview?(id); return }
        guard let record = try? line.library?.item(id) else { return }
        switch record.kind { case .image: showPreview(id); case .text: showTextPreview(id); case .link: showLinkPreview(id) }
    }

    private func performActionBarKeyboard(_ action: KeyboardAction, snapshot: ActionBarSnapshot) {
        switch action {
        case .searchShelf: searchContents(from: snapshot)
        case .search: actionBarLibrary(from: snapshot)?.model.onSearchFocus?()
        case .library: showLibrary()
        case .paste: pasteItems(snapshot.ids)
        case .upload: if let id = snapshot.singleID { uploadItem(id) }
        case .copy:
            do {
                guard let store = line.library, !snapshot.ids.isEmpty else { return }
                let items = try LibraryTransfer.pasteboardItems(store.records(snapshot.ids))
                if ClipboardTransfer.write(items, to: isolatedCopyBoard ?? .general) { try store.markCopied(snapshot.ids); reportActionStatus(L("Copied")); textPreview?.flashCopied(); linkPreview?.flashCopied() }
            } catch { reportActionStatus(error.localizedDescription) }
        case .preview: showActionBarPreview(snapshot)
        case .pin:
            do { try line.library?.toggleFavorite(snapshot.ids); if let session = previewSession { updatePreview(session) } }
            catch { reportActionStatus(error.localizedDescription) }
        case .pinToFolder:
            if snapshot.inLibrary { libraryController?.model.onPinToFolderRequested?(snapshot.ids) } else { showPinFolderPicker(snapshot.ids) }
        case .nameAndPin:
            if snapshot.inLibrary { libraryController?.nameAndPin(snapshot.ids) } else { showNameAndPin(snapshot.ids) }
        case .tag:
            if snapshot.inLibrary { libraryController?.promptTag(ids: snapshot.ids) } else { showTagPicker(snapshot.ids) }
        case .copyImageText: if let id = snapshot.singleID { copyImageText(id) }
        case .pinnedOnly:
            if snapshot.inLibrary { libraryController?.model.togglePinnedOnly() }
            else if snapshot.origin == .shelfPreview, let session = previewSession { _ = session.toggleFavorites(); updatePreview(session) }
            else { line.setActiveFavorites(!line.activeFavoritesOnly) }
        case .open:
            if let id = snapshot.singleID, let record = try? line.library?.item(id), let url = record.linkURL { NSWorkspace.shared.open(url) }
        case .editText, .finishEditing, .cropImage, .markup, .markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText:
            if snapshot.inLibrary { _ = libraryController?.performPreviewAction(action, id: snapshot.singleID) }
            else {
                if !snapshot.inPreview { showActionBarPreview(snapshot) }
                if action == .editText { textPreview?.beginEditing() }
                else if action == .finishEditing { _ = textPreview?.finishEditing() }
                else { _ = preview?.perform(action) }
            }
        case .allTypes, .images, .texts, .links:
            _ = actionBarLibrary(from: snapshot)?.model.perform(action)
        case .focusNextPane, .focusPreviousPane, .undoTrash, .newNote, .newFolder:
            _ = actionBarLibrary(from: snapshot)?.model.perform(action)
        case .export: exportActionBarItems(snapshot)
        case .trash: trashActionBarItems(snapshot)
        case .removeFromLine:
            if snapshot.origin == .shelfPreview, let session = previewSession { removePreviewItem(session) }
            else { line.removeFromShelf(snapshot.ids, on: snapshot.shelf, focusedID: snapshot.focusedID) }
        case .undoRemoveFromLine:
            if snapshot.origin == .shelfPreview, let session = previewSession { undoPreviewRemoval(session) }
            else { line.undoShelfRemoval() }
        case .close:
            if snapshot.origin == .libraryPreview { libraryController?.dismissPreviews() }
            else if snapshot.origin == .library { libraryController?.window?.performClose(nil) }
            else if snapshot.origin == .shelfPreview { closePreview() }
            else if snapshot.origin == .line { setRevealed(false) }
            else { snapshot.parent?.performClose(nil) }
        case .toggleImages, .toggleTexts, .toggleLinks, .toggleShelves, .switchShelf:
            if snapshot.origin == .shelfPreview { closePreview() }
            if snapshot.origin == .libraryPreview { libraryController?.dismissPreviews() }
            if !isRevealed { reveal() }
            _ = keyboard.perform(action)
        case .previous, .next, .up, .down, .first, .last, .previousPage, .nextPage,
             .extendPrevious, .extendNext, .extendUp, .extendDown, .selectAll,
             .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9:
            if snapshot.origin == .libraryPreview { _ = libraryController?.performPreviewNavigation(action) }
            else if snapshot.origin == .library { _ = libraryController?.model.perform(action) }
            else if snapshot.origin == .shelfPreview, let session = previewSession {
                switch action {
                case .previous: movePreview(session, delta: -1)
                case .next: movePreview(session, delta: 1)
                case .up: movePreviewShelf(session, delta: -1)
                case .down: movePreviewShelf(session, delta: 1)
                case .first, .last: movePreviewToBoundary(session, last: action == .last)
                case .previousPage, .nextPage: movePreviewPage(session, delta: action == .previousPage ? -1 : 1)
                default: break
                }
            } else { _ = keyboard.perform(action) }
        case .commandPalette: break
        }
    }

    private func actionBarLibrary(from snapshot: ActionBarSnapshot) -> LibraryWindowController? {
        if snapshot.inLibrary, let controller = libraryController, controller.window?.isVisible == true {
            controller.dismissPreviews(); controller.window?.makeKeyAndOrderFront(nil)
            return controller
        }
        showLibrary(); libraryController?.dismissPreviews()
        return libraryController
    }

    private func performActionBarMenu(_ action: ActionBarMenuAction, snapshot: ActionBarSnapshot) {
        // Library commands deliberately open its normal window, then use the
        // same model/controller operations as the native menus and toolbar.
        func library() -> LibraryWindowController? { actionBarLibrary(from: snapshot) }
        func markup(_ command: ImageMarkupCommand) {
            if snapshot.inLibrary { _ = libraryController?.performMarkupCommand(command, id: snapshot.singleID) }
            else { if !snapshot.inPreview { showActionBarPreview(snapshot) }; _ = preview?.performMarkupCommand(command) }
        }
        switch action {
        case .settings: showSettings()
        case .clearUnsavedHistory: confirmClearHistory()
        case .settingsGeneral, .settingsHistory, .settingsSources, .settingsCloud, .settingsShortcuts, .settingsAbout:
            showSettings()
            settingsController?.model.section = action == .settingsGeneral ? .general : action == .settingsHistory ? .history : action == .settingsSources ? .sources : action == .settingsCloud ? .cloud : action == .settingsShortcuts ? .shortcuts : .about
        case .editDetails:
            guard let id = snapshot.singleID else { return }
            library()?.revealItemDetails(id)
        case .newNote: library()?.model.newNote()
        case .newFolder: library()?.createFolder()
        case .newSubfolder:
            if let controller = library(), case let .collection(id) = snapshot.libraryScope { controller.createFolder(parent: id) }
        case .renameFolder, .removeFolder:
            if let controller = library(), case let .collection(id) = snapshot.libraryScope, let folder = controller.model.collections.first(where: { $0.id == id }) {
                if action == .renameFolder { controller.renameFolder(folder) } else { controller.removeFolder(folder) }
            }
        case .renameTag, .removeTag:
            if let controller = library(), case let .tag(id) = snapshot.libraryScope, let tag = controller.model.tags.first(where: { $0.id == id }) {
                if action == .renameTag { controller.renameTag(tag) } else { controller.removeTag(tag) }
            }
        case .retain, .restore:
            do { if action == .retain { try line.library?.retain(snapshot.ids) } else { try line.library?.restore(snapshot.ids) } }
            catch { reportActionStatus(error.localizedDescription) }
        case .scopeSaved: library()?.model.changeScope(.saved)
        case .scopeFavorites: library()?.model.changeScope(.favorites)
        case .scopeUnorganized: library()?.model.changeScope(.unorganized)
        case .scopeRecent: library()?.model.changeScope(.recent)
        case .scopeTrash: library()?.model.changeScope(.trash)
        case .grid, .list: library()?.model.listMode = action == .list
        case .toggleSidebar: library()?.splitController.toggleSidebar(nil)
        case .toggleInspector: library()?.model.inspectorVisible.toggle()
        case .toggleFullscreen: library()?.toggleFullscreen()
        case .filters: library()?.toolbarController.presentFilters(relativeTo: nil)
        case .clearFilters: library()?.model.clearFilters()
        case .sortNewest: library()?.model.setSort(.newest)
        case .sortOldest: library()?.model.setSort(.oldest)
        case .sortTitle: library()?.model.setSort(.title)
        case .sortTitleDescending: library()?.model.setSort(.titleDescending)
        case .sortCopied: library()?.model.setSort(.copied)
        case .sortRelevance: library()?.model.setSort(.relevance)
        case .searchAll: library()?.model.setSearchMode(.all)
        case .searchText: library()?.model.setSearchMode(.text)
        case .searchVisual: library()?.model.setSearchMode(.visual)
        case .daysAny: library()?.model.setDays(nil)
        case .days7: library()?.model.setDays(7)
        case .days30: library()?.model.setDays(30)
        case .refreshLink: metadataService?.request(snapshot.ids, force: true)
        case .openFile, .quickLook, .revealFile:
            guard let id = snapshot.singleID, let record = try? line.library?.item(id), let url = record.fileURL else { return }
            if action == .openFile { NSWorkspace.shared.open(url) }
            else if action == .quickLook { QuickLook.shared.show([url], at: 0) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .saveToDesktop: if let id = snapshot.singleID { line.saveToDesktop(id) }
        case .takeDownLeft, .takeDownRight: if let id = snapshot.singleID { line.takeDown(id, toTheLeft: action == .takeDownLeft) }
        case .trimVideo:
            if let id = snapshot.singleID, line.items.contains(where: { $0.id == id }) { line.markup(id) }
            else if let id = snapshot.singleID, let store = line.library { Trim.shared.edit(id, store: store, size: NSSize(width: 720, height: 450)) }
        case .reuploadToR2: if let id = snapshot.singleID { uploadItem(id, forceReupload: true) }
        case .resetZoom: markup(.resetZoom)
        case .markupUndo: markup(.undo)
        case .markupRedo: markup(.redo)
        case .markupDelete: markup(.deleteSelected)
        case .markupClear: markup(.clear)
        case .markupSave: markup(.save)
        case .markupFinish: markup(.finishEditing)
        case .markupStyles: markup(.styles)
        case .toggleLine: toggle()
        case .copyLatestImage: copyLatest()
        case .uploadLatestItem: uploadLatest()
        case .openScreenshotsFolder: NSWorkspace.shared.open(watcher?.folder ?? line.historyFiles.inbox)
        case .checkUpdates: showUpdateSettings(); appUpdates.manualCheck()
        case .installUpdate:
            guard let build = appUpdates.availableBuild else { return }
            showUpdateSettings(); appUpdates.installAvailableUpdate(expectedBuild: build)
        case .upstreamReleases: NSWorkspace.shared.open(Self.updatesURL)
        case .quit: NSApp.terminate(nil)
        }
    }

    private func exportActionBarItems(_ snapshot: ActionBarSnapshot) {
        if snapshot.inLibrary { libraryController?.exportSelection(ids: snapshot.ids); return }
        guard let store = line.library, !snapshot.ids.isEmpty else { return }
        operationBusy = true; defer { operationBusy = false }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false; chooser.prompt = L("Export copies")
        guard chooser.runModal() == .OK, let folder = chooser.url else { return }
        do {
            let result = try store.files.export(LibraryTransfer.exportSources(store.records(snapshot.ids), store: store), to: folder)
            reportActionStatus(String(format: L("Exported %d · failed %d"), result.copies.count, result.failed.count))
        } catch { reportActionStatus(error.localizedDescription) }
    }

    private func trashActionBarItems(_ snapshot: ActionBarSnapshot) {
        if snapshot.inLibrary { libraryController?.confirmTrash(ids: snapshot.ids); return }
        guard let store = line.library, !snapshot.ids.isEmpty else { return }
        operationBusy = true; defer { operationBusy = false }
        let alert = NSAlert(); alert.messageText = String(format: L("Move %d items to recoverable Trash?"), snapshot.ids.count)
        alert.informativeText = L("You can restore them from Library → Trash. Original files stay in place.")
        alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.trash(snapshot.ids); if let session = previewSession { updatePreview(session) } }
        catch { reportActionStatus(error.localizedDescription) }
    }
    private func copyLatest() { if let id = line.newestID { line.copy(id) } }

    func uploadItem(_ id: UUID, forceReupload: Bool = false) {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        let needsNetwork = forceReupload || ((try? line.library?.item(id))?.uploadedURL == nil)
        if needsNetwork, r2Coordinator.isConfigured {
            reportActionStatus(L("Uploading to R2…"))
        }
        r2Coordinator.upload(id, forceReupload: forceReupload) { [weak self] outcome in
            self?.handleUploadOutcome(outcome, emptyMessage: L("Select one item first"))
        }
    }

    func uploadLatest() {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        if r2Coordinator.isConfigured {
            reportActionStatus(L("Uploading to R2…"))
        }
        r2Coordinator.uploadLatest { [weak self] outcome in
            self?.handleUploadOutcome(outcome, emptyMessage: L("No items in this view"))
        }
    }

    private func handleUploadOutcome(_ outcome: R2UploadCoordinator.Outcome, emptyMessage: String) {
        switch outcome {
        case .uploaded:
            line.playFeedbackSound()
            if let session = previewSession { updatePreview(session) }
            reportActionStatus(L("Uploaded — link copied"))
        case .copiedExisting:
            line.playFeedbackSound()
            if let session = previewSession { updatePreview(session) }
            reportActionStatus(L("Public link copied"))
        case .notConfigured:
            reportActionStatus(L("Configure Cloudflare R2 in Settings first"))
            if watchesFiles {
                showSettings()
                settingsController?.model.section = .cloud
            }
        case .unavailable:
            reportActionStatus(emptyMessage)
        case let .failed(message):
            reportActionStatus(message)
        }
    }

    private func registerUploadShortcut(_ value: KeyShortcut?, persist: Bool = true) {
        defer { clearResolvedShortcutWarning() }
        guard let value else {
            uploadHotKey?.invalidate(); uploadHotKey = nil
            if persist { line.saveUploadLatestShortcut(nil) }
            return
        }
        guard value.isValid else { return }
        if uploadHotKey?.isRegistered == true && value == line.uploadLatestShortcut { return }
        let replacement = HotKey(keyCode: value.keyCode, modifiers: value.modifiers) { [weak self] in self?.uploadLatest() }
        guard replacement.isRegistered else {
            line.notice = L("Shortcut unavailable; the previous shortcut is kept")
            return
        }
        uploadHotKey?.invalidate(); uploadHotKey = replacement
        if persist { line.saveUploadLatestShortcut(value) }
        settingsController?.model.refresh()
    }

    private func recordUploadShortcut() {
        shortcutRecorder?.window.close()
        let recorder = ShortcutRecorder(); shortcutRecorder = recorder
        recorder.onRestoreFailure = { [weak self] in self?.reportShortcutRestoreFailure() }
        recorder.window.title = L("Upload latest item")
        recorder.onFinish = { [weak self] value in
            self?.shortcutRecorder = nil
            if let value { self?.registerUploadShortcut(value) }
            self?.settingsController?.model.refresh()
            if self?.isRevealed == true { self?.focusLine() }
        }
        recorder.show()
    }
    private func registerLibraryShortcut(_ value: KeyShortcut?, persist: Bool = true) {
        defer { clearResolvedShortcutWarning() }
        guard value != nil else { libraryHotKey?.invalidate(); libraryHotKey = nil; if persist { line.saveLibraryShortcut(nil) }; return }
        guard let value, value.isValid else { return }
        if libraryHotKey?.isRegistered == true && value == line.libraryShortcut { return }
        let replacement = HotKey(keyCode: value.keyCode, modifiers: value.modifiers) { [weak self] in self?.showLibrary() }
        guard replacement.isRegistered else {
            if persist { let alert = NSAlert(); alert.messageText = L("Shortcut unavailable; the previous shortcut is kept"); alert.runModal() }
            return
        }
        libraryHotKey?.invalidate(); libraryHotKey = replacement; if persist { line.saveLibraryShortcut(value) }
    }
    private func recordLibraryShortcut() {
        shortcutRecorder?.window.close(); let recorder = ShortcutRecorder(); shortcutRecorder = recorder
        recorder.onRestoreFailure = { [weak self] in self?.reportShortcutRestoreFailure() }
        recorder.onFinish = { [weak self] value in self?.shortcutRecorder = nil; if let value { self?.registerLibraryShortcut(value) }; self?.settingsController?.model.refresh() }
        recorder.show()
    }

    /// Register the replacement before dropping the old key or changing preferences.
    /// A shortcut occupied by another app cannot silently disable the saved one.
    private func registerCopyShortcut(_ value: KeyShortcut?, persist: Bool = true) {
        defer { clearResolvedShortcutWarning() }
        if value == nil {
            copyHotKey?.invalidate(); copyHotKey = nil
            if persist { line.saveCopyLatestShortcut(nil) }
            return
        }
        guard let value, value.isValid else { return }
        if copyHotKey?.isRegistered == true && value == line.copyLatestShortcut { return }
        let replacement = HotKey(keyCode: value.keyCode, modifiers: value.modifiers) { [weak self] in self?.copyLatest() }
        guard replacement.isRegistered else {
            line.notice = L("Shortcut unavailable; the previous shortcut is kept")
            if persist {
                let alert = NSAlert(); alert.messageText = L("Shortcut unavailable; the previous shortcut is kept")
                alert.runModal()
            }
            return
        }
        copyHotKey?.invalidate(); copyHotKey = replacement
        if persist { line.saveCopyLatestShortcut(value) }
    }

    private func recordShortcut() {
        shortcutRecorder?.window.close()
        let recorder = ShortcutRecorder(); shortcutRecorder = recorder
        recorder.onRestoreFailure = { [weak self] in self?.reportShortcutRestoreFailure() }
        recorder.onFinish = { [weak self] value in
            self?.shortcutRecorder = nil
            if let value { self?.registerCopyShortcut(value) }
            self?.settingsController?.model.refresh()
            if self?.isRevealed == true { self?.focusLine() }
        }
        recorder.show()
    }

    private func exportSelection() {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        let sources: [(url: URL, name: String)]
        do {
            if line.activeShelf == .links, let store = line.library { sources = try LibraryTransfer.exportSources(line.links.selectedEntries, store: store) }
            else if line.showingTexts { sources = try line.texts.exportSources(line.texts.selectedEntries) }
            else { sources = line.selectedItems.map {
                (url: $0.url, name: HistoryFiles.exportName(for: $0.url, originalPath: $0.originalPath))
            } }
        } catch { line.notice = L("Could not export copies"); return }
        guard !sources.isEmpty else { return }
        operationBusy = true; defer { operationBusy = false }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false; chooser.prompt = L("Export copies")
        guard chooser.runModal() == .OK, let folder = chooser.url else { return }
        do {
            let result = try line.historyFiles.export(sources, to: folder)
            line.notice = String(format: L("Exported %d · failed %d"), result.copies.count, result.failed.count)
        } catch { line.notice = L("Could not export copies") }
        focusLine()
    }

    private func trashSelection() {
        guard flushPreviewEdits(), libraryController?.flush() ?? true else { return }
        if line.activeShelf == .links {
            let snapshot = line.links.selectedEntries.map(\.id); guard !snapshot.isEmpty else { return }
            let alert = NSAlert(); alert.messageText = String(format: L("Move %d items to recoverable Trash?"), snapshot.count)
            alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { line.links.trash(snapshot) }; focusLine(); return
        }
        if line.showingTexts {
            let snapshot = line.texts.selectedEntries; guard !snapshot.isEmpty else { return }
            operationBusy = true; defer { operationBusy = false }
            let alert = NSAlert(); alert.messageText = L("Move selected texts to recoverable Trash?")
            alert.informativeText = String(format: L("%d selected"), snapshot.count)
            alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { line.texts.trash(snapshot.map(\.id)) }
            focusLine(); return
        }
        trashImages(line.trashSelectionSnapshot())
    }

    private func trashImages(_ snapshot: Line.TrashSelection) {
        guard !snapshot.images.isEmpty else { return }
        operationBusy = true; defer { operationBusy = false }
        let alert = NSAlert()
        alert.messageText = L("Remove selected images?")
        alert.informativeText = String(format: L("%d app copies will move to recoverable Trash. %d original files stay in place; only their history entries are removed."), snapshot.appCopies, snapshot.originals)
        alert.addButton(withTitle: snapshot.appCopies > 0 ? L("Move app copies to Trash") : L("Remove history entries"))
        alert.addButton(withTitle: L("Cancel"))
        line.trashSelection(snapshot, confirmed: alert.runModal() == .alertFirstButtonReturn)
        focusLine()
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
