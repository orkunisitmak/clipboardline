import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum AppIdentity {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tendedero" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var statusSymbol: String { Bundle.main.bundleIdentifier?.hasPrefix("local.clipboardline.") == true ? "doc.on.clipboard" : "tshirt" }
}

/// Every control uses the same operation as the original menu. Reading or
/// opening settings never writes preferences or starts capture.
@MainActor
final class SettingsModel: ObservableObject {
    let line: Line
    let allowsSystemChanges: Bool
    let updates: AppUpdateController
    let r2: R2UploadCoordinator
    @Published var updatesRequest = 0
    @Published var section: SettingsSection = .general
    @Published var shortcutWarning: String?
    var onCommands: () -> Void = {}
    var setSize: (Layout.Size) -> Void = { _ in }
    var setImages: (Bool) -> Void = { _ in }
    var setTexts: (Bool) -> Void = { _ in }
    var setLinks: (Bool) -> Void = { _ in }
    var setMetadata: (Bool) -> Void = { _ in }
    var setLibraryShortcut: (KeyShortcut?) -> Void = { _ in }
    var recordLibraryShortcut: () -> Void = {}
    var setSearchShortcut: (KeyShortcut?) -> Void = { _ in }
    var recordSearchShortcut: () -> Void = {}
    var setUploadShortcut: (KeyShortcut?) -> Void = { _ in }
    var recordUploadShortcut: () -> Void = {}
    var requestPastePermission: () -> Void = {}
    var recordContextShortcut: (KeyboardAction) -> Void = { _ in }
    var openLibrary: () -> Void = {}
    var setScreenshots: (Bool) -> Void = { _ in }
    var refreshVisibility: () -> Void = {}
    var addFolder: () -> Void = {}
    var removeFolder: (URL) -> Void = { _ in }
    var changeToggleShortcut: () -> Void = {}
    var setCopyShortcut: (KeyShortcut?) -> Void = { _ in }
    var recordCopyShortcut: () -> Void = {}
    var changeLogin: () -> Void = {}
    var clearHistory: (LibraryKind?) -> Void = { _ in }
    var reopenForLanguage: () -> Void = {}
    let languageDefaults: UserDefaults
    private let launchLanguage: String
    private let pastePermissionGranted: () -> Bool

    init(line: Line, allowsSystemChanges: Bool = true, languageDefaults: UserDefaults = .standard, updates: AppUpdateController? = nil,
         r2: R2UploadCoordinator? = nil, pastePermissionGranted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.line = line; self.allowsSystemChanges = allowsSystemChanges
        self.updates = updates ?? AppUpdateController(enabled: allowsSystemChanges)
        self.r2 = r2 ?? R2UploadCoordinator(store: line.library, defaults: line.defaults,
            secrets: allowsSystemChanges ? KeychainR2SecretStore() : InMemoryR2SecretStore())
        self.languageDefaults = languageDefaults; launchLanguage = LanguagePreferences.selection(languageDefaults)
        self.pastePermissionGranted = pastePermissionGranted
    }
    var language: String { LanguagePreferences.selection(languageDefaults) }
    var languageNeedsRestart: Bool { language != launchLanguage }
    // Re-read on the existing presentation/activation refresh rather than
    // retaining a warning after the user grants access in System Settings.
    var needsPastePermission: Bool { !pastePermissionGranted() }

    func refresh() { objectWillChange.send() }
    func binding<Value>(get: @escaping () -> Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { get() }, set: { [weak self] value in set(value); self?.refresh() })
    }
    var copyShortcutChoice: Int {
        guard let value = line.copyLatestShortcut else { return -1 }
        return KeyShortcut.presets.firstIndex(of: value) ?? -2
    }
}

final class SettingsNativeWindow: NSWindow {
    var onCommandKey: ((NSEvent) -> Bool)?
    var onBeforeMouseKeyFocus: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onCommandKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        Self.prepareForMouseKeyFocus(event, isKeyWindow: isKeyWindow, onEntry: onBeforeMouseKeyFocus)
        super.sendEvent(event)
    }
    static func prepareForMouseKeyFocus(_ event: NSEvent, isKeyWindow: Bool, onEntry: (() -> Void)?) {
        guard event.type == .leftMouseDown, !isKeyWindow else { return }
        onEntry?()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    var onBeforeMouseKeyFocus: (() -> Void)?
    init(model: SettingsModel) {
        self.model = model
        let window = SettingsNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) — \(L("Settings"))"
        window.minSize = NSSize(width: 690, height: 540)
        window.isReleasedWhenClosed = false
        window.onCommandKey = { [weak model] event in
            guard let model, !event.modifierFlags.intersection([.command, .control]).isEmpty,
                  model.line.keyboardBindings.action(for: event, in: .library) == .commandPalette else { return false }
            model.onCommands(); return true
        }
        window.contentView = NSHostingView(rootView: SettingsView(model: model, line: model.line))
        window.center()
        super.init(window: window)
        window.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforeMouseKeyFocus?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if model.section == .updates { model.updates.refreshWhenUpdatesAreShown() }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, history, sources, cloud, shortcuts, updates, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: L("General")
        case .history: L("History")
        case .sources: L("Sources")
        case .cloud: L("Cloud upload")
        case .shortcuts: L("Keyboard shortcuts")
        case .updates: L("Updates")
        case .about: L("About")
        }
    }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .history: "clock.arrow.circlepath"
        case .sources: "tray.and.arrow.down"
        case .cloud: "icloud.and.arrow.up"
        case .shortcuts: "keyboard"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var line: Line
    @State private var historyCleanupKind: LibraryKind?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: AppIdentity.statusSymbol).font(.system(size: 28)).foregroundStyle(.tint).accessibilityLabel(AppIdentity.name)
                    Text(AppIdentity.name).font(.headline)
                    Text(AppIdentity.version).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 22)
                VStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { item in
                        Button { model.section = item } label: {
                            Label(item.title, systemImage: item.icon).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 9)
                                .background(model.section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(model.section == item ? Color.white : Color.primary)
                        }.buttonStyle(.plain).accessibilityAddTraits(model.section == item ? .isSelected : [])
                    }
                }
                Spacer()
            }.padding(.horizontal, 10).frame(width: 190).background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.section.title).font(.title2.bold())
                    Spacer()
                    Button(action: model.onCommands) { Label(L("Actions"), systemImage: "command") }
                        .help(L("Actions") + " · " + line.keyboardBindings.title(.commandPalette))
                        .accessibilityIdentifier("settings-actions")
                }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
                Form {
                    switch model.section {
                    case .general: general
                    case .history: history
                    case .sources: sources
                    case .cloud: CloudUploadSettingsView(r2: model.r2)
                    case .shortcuts: shortcuts
                    case .updates: AppUpdatesView(updates: model.updates)
                    case .about: about
                    }
                }.formStyle(.grouped)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onReceive(model.$updatesRequest) { if $0 > 0 { model.section = .updates } }
    }

    private var general: some View {
        Group {
            Section(L("Appearance")) {
                Picker(L("Language"), selection: model.binding(get: { model.language }, set: { _ = LanguagePreferences.set($0, defaults: model.languageDefaults) })) {
                    Text(L("System default")).tag("")
                    ForEach(LanguagePreferences.available, id: \.self) { Text(LanguagePreferences.name($0)).tag($0) }
                }
                if model.languageNeedsRestart {
                    Button(L("Reopen to apply language"), action: model.reopenForLanguage)
                    Text(L("Open edits are saved before the app reopens.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Shelf.allCases, id: \.self) { shelf in
                    Toggle(shelf.title, isOn: model.binding(get: { line.presentation.shelves.contains(shelf) }, set: { line.setShelfVisible(shelf, visible: $0) }))
                        .disabled(line.presentation.shelves == [shelf])
                }
                Picker(L("Colors"), selection: model.binding(get: { line.theme }, set: { line.setTheme($0) })) {
                    ForEach(ShelfTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L("Size"), selection: model.binding(get: { line.size }, set: model.setSize)) {
                    Text(L("Small")).tag(Layout.Size.small)
                    Text(L("Medium")).tag(Layout.Size.medium)
                    Text(L("Large")).tag(Layout.Size.large)
                }
            }
            Section {
                Button(L("Open library"), action: model.openLibrary).disabled(line.library == nil)
                Text(L("Favorites, folders and tags keep items permanently. Other copies follow your history setting.")).font(.caption).foregroundStyle(.secondary)
            } header: { Text(L("Library")) }
            Section(L("Bring the line down")) {
                Toggle(L("When the pointer rests in the menu bar"), isOn: model.binding(get: { AppDelegate.opensFromMenuBar }, set: { AppDelegate.opensFromMenuBar = $0 }))
                Toggle(L("When something new hangs"), isOn: model.binding(get: { AppDelegate.peeksAtNew }, set: { AppDelegate.peeksAtNew = $0 }))
                Toggle(L("Over full screen apps"), isOn: model.binding(get: { FullScreen.showLineOver }, set: { FullScreen.showLineOver = $0; model.refreshVisibility() }))
            }
            Section {
                Toggle(L("Sounds"), isOn: model.binding(get: { line.soundOn }, set: { line.soundOn = $0 }))
                Toggle(L("Open at login"), isOn: model.binding(get: { SMAppService.mainApp.status == .enabled }, set: { _ in model.changeLogin() }))
                    .disabled(!model.allowsSystemChanges)
            }
        }
    }

    private var sources: some View {
        Group {
            Section {
                Toggle(L("Hang copied images"), isOn: model.binding(get: { ClipboardWatcher.isEnabled }, set: model.setImages))
                Toggle(L("Hang copied text"), isOn: model.binding(get: { TextClipboardWatcher.isEnabled }, set: model.setTexts))
                Toggle(L("Capture copied links"), isOn: model.binding(get: { LinkHistory.isEnabled }, set: model.setLinks))
            } header: { Text(L("Clipboard")) } footer: {
                Text(L("Copies are saved locally. Text and link capture is silent. A single web address goes to Links; paragraphs stay as text."))
            }
            Section {
                Toggle(L("Fetch link titles and thumbnails"), isOn: model.binding(get: { LinkMetadataService.isEnabled }, set: model.setMetadata))
            } header: { Text(L("Link previews")) } footer: {
                Text(L("Contacts the linked website or YouTube in the background. Private markers, local addresses and links with known secret parameters are skipped."))
            }
            Section {
                Toggle(L("Handle screenshots"), isOn: model.binding(get: { Inbox.isEnabled }, set: model.setScreenshots))
                    .disabled(!model.allowsSystemChanges)
            } header: { Text(L("Screenshots")) } footer: {
                Text(L("Screenshots hang instantly and skip the Desktop. Your macOS screenshot settings are restored when the app quits."))
            }
            Section {
                ForEach(AppDelegate.extraFolders, id: \.path) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FileManager.default.displayName(atPath: folder.path))
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "folder") }.accessibilityLabel(L("Open folder"))
                        Button { model.removeFolder(folder); model.refresh() } label: { Image(systemName: "minus.circle") }.accessibilityLabel(L("Stop Watching"))
                    }
                }
                Button(L("Add Folder…")) { model.addFolder(); model.refresh() }
                    .disabled(AppDelegate.extraFolders.count >= AppDelegate.maxExtraFolders || !model.allowsSystemChanges)
            } header: { Text(L("Also watch folders")) } footer: {
                Text(L("Watch up to three folders for new images. Removing a folder leaves its files untouched."))
            }
        }
    }

    private var history: some View {
        let cleanupCount = try? line.library?.unsavedHistoryCount(kind: historyCleanupKind)
        return Section {
            ForEach(LibraryKind.allCases, id: \.self) { kind in
                Picker(kind == .image ? L("Images") : kind == .text ? L("Texts") : L("Links"), selection: model.binding(get: { line.retentionDays(for: kind) }, set: { line.setRetentionDays($0, for: kind) })) {
                    ForEach(ImageHistory.dayChoices, id: \.self) { Text(String(format: L("Keep for %d days"), $0)).tag($0) }
                }
            }
            Picker(L("Copies to clear"), selection: $historyCleanupKind) {
                Text(L("All types")).tag(nil as LibraryKind?)
                Text(L("Images")).tag(LibraryKind.image as LibraryKind?)
                Text(L("Texts")).tag(LibraryKind.text as LibraryKind?)
                Text(L("Links")).tag(LibraryKind.link as LibraryKind?)
            }
            if let count = cleanupCount {
                Text(String(format: L("%d unsaved copies"), count)).font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Clear unsaved copies…")) { model.clearHistory(historyCleanupKind) }
                .disabled(line.library == nil || cleanupCount == 0)
        } header: { Text(L("History")) } footer: {
            Text(L("Unsaved copies expire to recoverable Trash. Saved items and original files are kept."))
        }
    }

    private var shortcuts: some View {
        Group {
            if let warning = model.shortcutWarning {
                Section {
                    Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.orange).accessibilityIdentifier("shortcut-recording-warning")
                }
            }
            Section(L("Search shelves from other apps")) {
                LabeledContent(L("Shortcut")) { Text(line.globalSearchShortcut?.title ?? L("Off")).monospaced() }
                HStack {
                    Button(L("Record shortcut…"), action: model.recordSearchShortcut)
                    Button(L("Off")) { model.setSearchShortcut(nil); model.refresh() }
                }
                Text(L("This shortcut opens the shelves with search ready.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Paste into previous app")) {
                if model.needsPastePermission {
                    Text(L("Accessibility permission is needed to paste into another app.")).font(.caption).foregroundStyle(.secondary)
                }
                if #available(macOS 27, *) {
                    Button(L("Open Device Control and Data Access"), action: model.requestPastePermission)
                } else {
                    Button(L("Open Accessibility Settings"), action: model.requestPastePermission)
                }
            }
            Section(L("Show or hide the line")) {
                LabeledContent(L("Shortcut")) { Text(Shortcut.current?.display ?? L("None")).monospaced() }
                Button(L("Change Shortcut…"), action: model.changeToggleShortcut)
            }
            Section(L("Copy latest image")) {
                Picker(L("Copy-latest shortcut"), selection: model.binding(get: { model.copyShortcutChoice }, set: {
                    if $0 == -1 { model.setCopyShortcut(nil) }
                    else if KeyShortcut.presets.indices.contains($0) { model.setCopyShortcut(KeyShortcut.presets[$0]) }
                })) {
                    Text(L("Off")).tag(-1)
                    ForEach(KeyShortcut.presets.indices, id: \.self) { Text(KeyShortcut.presets[$0].title).tag($0) }
                    if let custom = line.copyLatestShortcut, model.copyShortcutChoice == -2 { Text(custom.title).tag(-2) }
                }
                Button(L("Record shortcut…"), action: model.recordCopyShortcut)
            }
            Section(L("Upload latest item")) {
                LabeledContent(L("Shortcut")) { Text(line.uploadLatestShortcut?.title ?? L("Off")).monospaced() }
                HStack {
                    Button(L("Record shortcut…"), action: model.recordUploadShortcut)
                    Button(L("Off")) { model.setUploadShortcut(nil); model.refresh() }
                }
                Text(L("Uploads the newest item on the shelves to Cloudflare R2 and copies its public link.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Browsing shortcuts")) {
                Text(L("Single keys work while browsing the line, Library or a preview. Typing and standard editing shortcuts stay with the editor.")).font(.caption).foregroundStyle(.secondary)
                shortcutRow(.library)
                ForEach(KeyboardAction.allCases.filter { $0.settingsGroup == 0 && $0 != .library }) { shortcutRow($0) }
                DisclosureGroup(L("Navigation and selection")) {
                    ForEach(KeyboardAction.allCases.filter { $0.settingsGroup == 1 }) { shortcutRow($0) }
                }
                DisclosureGroup(L("Library actions")) {
                    ForEach(KeyboardAction.allCases.filter { $0.settingsGroup == 2 }) { shortcutRow($0) }
                }
                Button(L("Reset all browsing shortcuts")) { do { try line.keyboardBindings.reset(); line.notice = nil } catch { line.notice = error.localizedDescription }; model.refresh() }
                if let notice = line.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            Section(L("Open library")) {
                LabeledContent(L("Shortcut")) { Text(line.libraryShortcut?.title ?? L("Off")).monospaced() }
                HStack {
                    Button(L("Use ⌃⌥L")) { model.setLibraryShortcut(KeyShortcut(keyCode: 37, modifiers: 4096 | 2048, keyLabel: "L")); model.refresh() }
                    Button(L("Record shortcut…"), action: model.recordLibraryShortcut)
                    Button(L("Off")) { model.setLibraryShortcut(nil); model.refresh() }
                }
                Text(L("This shortcut opens Library from other apps. The browsing shortcut above works on the line.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutRow(_ action: KeyboardAction) -> some View {
        LabeledContent {
            HStack {
                Button(line.keyboardBindings.title(action).isEmpty ? L("Off") : line.keyboardBindings.title(action)) { model.recordContextShortcut(action) }
                    .monospaced().accessibilityLabel(action.title).help(L("Record shortcut…"))
                Menu {
                    Button(L("Off")) { do { try line.keyboardBindings.set([], for: action) } catch { line.notice = error.localizedDescription }; model.refresh() }
                    Button(L("Reset to default")) { do { try line.keyboardBindings.reset(action); line.notice = nil } catch { line.notice = error.localizedDescription }; model.refresh() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(action.title + " · " + L("Settings"))
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) { Text(action.title); Text(action.scopeTitle).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain)
    }

    private var about: some View {
        Group {
            Section {
                LabeledContent(L("Application"), value: AppIdentity.name)
                LabeledContent(L("Version"), value: "\(AppIdentity.version) (\(AppIdentity.build))")
                Text(L("Image, text and link shelves, with a private local library."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L("Check for updates…")) { model.section = .updates; model.updates.manualCheck() }
            }
            Section {
                Button(L("Check upstream releases…")) { NSWorkspace.shared.open(AppDelegate.updatesURL) }
            }
        }
    }
}

@MainActor
private struct CloudUploadSettingsView: View {
    @ObservedObject var r2: R2UploadCoordinator
    @State private var draftSecret = ""
    @State private var secretError: String?

    private func field(_ get: @escaping (R2Configuration) -> String, _ set: @escaping (inout R2Configuration, String) -> Void) -> Binding<String> {
        Binding(
            get: { get(r2.configuration) },
            set: { value in
                var next = r2.configuration
                set(&next, value)
                r2.saveConfiguration(next)
            }
        )
    }

    var body: some View {
        Section {
            TextField(L("Account ID or HTTPS endpoint"), text: field({ $0.accountId }, { $0.accountId = $1 }))
            TextField(L("Bucket name"), text: field({ $0.bucket }, { $0.bucket = $1 }))
            TextField(L("Public base URL"), text: field({ $0.publicBaseUrl }, { $0.publicBaseUrl = $1 }))
            TextField(L("Key prefix (optional)"), text: field({ $0.keyPrefix }, { $0.keyPrefix = $1 }))
        } header: { Text(L("Cloudflare R2")) } footer: {
            Text(L("Uploads use your own Cloudflare R2 bucket via S3-compatible HTTPS. After uploading, the public URL is copied to the clipboard."))
        }
        Section {
            TextField(L("Access Key ID"), text: field({ $0.accessKeyId }, { $0.accessKeyId = $1 }))
            SecureField(L("Secret Access Key"), text: $draftSecret).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("Save secret key")) {
                    do { try r2.saveSecret(draftSecret); draftSecret = ""; secretError = nil }
                    catch { secretError = error.localizedDescription }
                }.disabled(draftSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Remove secret key")) {
                    do { try r2.clearSecret(); draftSecret = ""; secretError = nil }
                    catch { secretError = error.localizedDescription }
                }.disabled(!r2.hasSavedSecret)
                if r2.hasSavedSecret {
                    Label(L("Stored in Keychain"), systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let secretError {
                Text(secretError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: { Text(L("Credentials")) } footer: {
            Text(L("Your Secret Access Key is stored in this Mac’s Keychain and is never written to preferences."))
        }
        Section(L("Connection")) {
            HStack {
                Button(L("Test connection")) {
                    let trimmed = draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        do { try r2.saveSecret(trimmed); draftSecret = ""; secretError = nil }
                        catch { secretError = error.localizedDescription; return }
                    }
                    r2.testConnection()
                }.disabled(r2.testingConnection)
                if r2.testingConnection { ProgressView().controlSize(.small) }
            }
            if let status = r2.connectionStatus {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error = r2.connectionError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

@MainActor
private struct AppUpdatesView: View {
    @ObservedObject var updates: AppUpdateController
    @State private var token = ""
    var body: some View {
        if updates.usesPublicUpdates {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: AppIdentity.statusSymbol)
                        .font(.system(size: 32)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppIdentity.name).font(.title3.bold())
                        Text("\(AppIdentity.version) · \(AppIdentity.build)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updates.availableVersion != nil {
                        Label(L("Update available"), systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    }
                }.padding(.vertical, 8)
            }
        }
        Section(L("App updates")) {
            Toggle(L("Automatically check for updates"), isOn: Binding(
                get: { updates.automaticChecksEnabled },
                set: { updates.setAutomaticChecksEnabled($0) }
            ))
            .disabled(!updates.isConfigured)
            Text(updates.usesPublicUpdates
                ? L("Checks at launch and every hour. You choose when to download and install.")
                : L("Checks at launch, every 12 hours and when you open About. Installation starts only when you choose."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("New versions also appear in the menu bar. macOS may ask to allow notifications."))
                .font(.caption).foregroundStyle(.secondary)
            Text(updates.status).textSelection(.enabled)
            if let date = updates.lastSuccessfulCheck {
                LabeledContent(L("Last checked"), value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = updates.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if updates.busy {
                if let value = updates.progress { ProgressView(value: value) }
                else { ProgressView().controlSize(.small) }
            }
            HStack {
                if updates.usesPublicUpdates {
                    Button(updates.availableVersion == nil ? L("Check for updates…") : L("Update…")) {
                        if let build = updates.availableBuild { updates.installAvailableUpdate(expectedBuild: build) }
                        else { updates.manualCheck() }
                    }
                        .buttonStyle(.borderedProminent)
                    if let url = updates.releaseNotesURL { Link(L("Release notes"), destination: url) }
                } else {
                    Button(L("Check for updates…"), action: updates.manualCheck)
                    if let update = updates.available {
                        Button(L("Install and reopen"), action: updates.downloadAndInstall).buttonStyle(.borderedProminent)
                        Link(L("Release notes"), destination: update.releaseURL)
                    }
                }
            }.disabled(!updates.isConfigured || updates.busy)
            Text(L("Updates are downloaded only when you choose Install. Your history and settings stay on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { updates.refreshWhenUpdatesAreShown() }
        if updates.usesPublicUpdates {
            Section {
                Label(L("Signed updates · No account or token needed"), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else { Section(L("GitHub access")) {
            Text(L("For a private repository, create a fine-grained token for this repository with Contents: Read-only. The token is stored in this Mac’s Keychain."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Authorize saved token…"), action: updates.authorizeSavedToken)
            Text(L("macOS may ask once for access to a previously saved token. App updates keep this authorization."))
                .font(.caption).foregroundStyle(.secondary)
            SecureField(L("GitHub access token"), text: $token).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("Save token")) { updates.saveToken(token); token = "" }.disabled(token.isEmpty)
                Button(L("Disconnect GitHub"), action: updates.disconnect)
                if updates.hasSavedToken { Label(L("Token saved"), systemImage: "checkmark.shield") .font(.caption).foregroundStyle(.secondary) }
            }
        }.disabled(!updates.isConfigured || updates.busy) }
    }
}
