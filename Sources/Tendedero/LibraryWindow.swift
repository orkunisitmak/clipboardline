import AppKit
import SwiftUI

final class LibraryNativeWindow: NSWindow {
    var onKey: ((NSEvent, Bool) -> Bool)?
    var onBeforeMouseKeyFocus: (() -> Void)?
    var onCancelKeyboardFocus: (() -> Void)?
    var onSidebarKey: ((NSEvent) -> Bool)?
    private weak var protectedSearchField: NSSearchField?
    private var inMakeFirstResponder = false
    /// macOS 26's SwiftUI-backed NSSearchToolbarItem tears down its collapsed
    /// button responder asynchronously after beginSearchInteraction(), calling
    /// makeFirstResponder(nil). Preserve explicit search focus until another
    /// responder, Escape, click, or explicit endEditing supersedes it.
    func beginToolbarSearchFocus(for field: NSSearchField) { protectedSearchField = field }
    func cancelToolbarSearchFocus() { protectedSearchField = nil }
    override func endEditing(for object: Any?) {
        if !inMakeFirstResponder { protectedSearchField = nil }
        super.endEditing(for: object)
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let responder, responder !== self {
            if let field = protectedSearchField, responder !== field, responder !== field.currentEditor() {
                protectedSearchField = nil
            }
            inMakeFirstResponder = true; defer { inMakeFirstResponder = false }
            return super.makeFirstResponder(responder)
        }
        let wasEditingProtectedSearch: Bool = {
            guard responder == nil, let field = protectedSearchField else { return false }
            return firstResponder === field || (field.currentEditor() != nil && firstResponder === field.currentEditor())
        }()
        inMakeFirstResponder = true
        let result = super.makeFirstResponder(responder)
        inMakeFirstResponder = false
        if wasEditingProtectedSearch, let field = protectedSearchField,
           field.window === self, !field.isHiddenOrHasHiddenAncestor {
            field.selectText(nil)
        }
        return result
    }
    private var editingOrControlFocused: Bool {
        // Native controls own Space/Return/arrows, even with keyboard navigation
        // enabled. A focused button must never copy a selected card behind it.
        if firstResponder is NSOutlineView { return true }
        if firstResponder is NSCollectionView || firstResponder is NSTableView { return false }
        return firstResponder !== self
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        if onKey?(event, editingOrControlFocused) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        Self.prepareForMouseKeyFocus(event, isKeyWindow: isKeyWindow, onEntry: onBeforeMouseKeyFocus)
        if event.type == .leftMouseDown { onCancelKeyboardFocus?() }
        if event.type == .keyDown, attachedSheet == nil {
            if onSidebarKey?(event) == true { return }
            if onKey?(event, editingOrControlFocused) == true { return }
        }
        super.sendEvent(event)
    }
    static func prepareForMouseKeyFocus(_ event: NSEvent, isKeyWindow: Bool, onEntry: (() -> Void)?) {
        guard event.type == .leftMouseDown, !isKeyWindow else { return }
        onEntry?()
    }
}

@MainActor final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let model: LibraryModel
    let line: Line
    private let previews: LibraryPreviewController
    private(set) var pinFolderPicker: PinFolderPicker?
    private(set) var tagPicker: TagPicker?
    private(set) var nameAndPinPicker: NameAndPinPicker?
    var previewWindow: NSWindow? { previews.window }
    var previewCurrentID: UUID? { previews.currentID }
    var previewImage: ImagePreview? { previews.image }
    var previewTextIsEditing: Bool { previews.text?.isEditing == true }
    var keyboardActionIDs: [UUID] { if previewWindow?.isKeyWindow == true, let id = previews.currentID { return [id] }; return model.actionIDs }
    var keyboardFocusedID: UUID? { previewWindow?.isKeyWindow == true ? previews.currentID : model.focusedID }
    private var closingFullscreen = false
    private var focusGeneration = 0
    private(set) var splitController: LibrarySplitController!
    private(set) var toolbarController: LibraryToolbarController!
    var onSettings: (() -> Void)?
    var onBeforeMouseKeyFocus: (() -> Void)?
    var onBeforePreviewMouseKeyFocus: (() -> Void)?
    var onRefreshLink: ((UUID) -> Void)?
    init(store: LibraryStore, line: Line, copyPasteboard: NSPasteboard? = nil) {
        self.line = line; model = LibraryModel(store: store, copyPasteboard: copyPasteboard); previews = LibraryPreviewController(model: model)
        let window = LibraryNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppIdentity.name + " — " + L("Library")
        window.titlebarAppearsTransparent = true; window.minSize = NSSize(width: 870, height: 560)
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenPrimary]; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforeMouseKeyFocus?() }
        model.onFlushPreview = { [weak self] in self?.previews.flush() ?? true }
        previews.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforePreviewMouseKeyFocus?() }
        window.delegate = self
        splitController = LibrarySplitController(model: model, line: line, actions: self)
        window.contentViewController = splitController
        toolbarController = LibraryToolbarController(model: model, actions: self, split: splitController)
        toolbarController.searchField.onWillResignSearchFocus = { [weak window] in window?.cancelToolbarSearchFocus() }
        let focusSearch = model.onSearchFocus
        model.onSearchFocus = { [weak self] in self?.cancelDeferredFocus(); focusSearch?() }
        window.toolbar = toolbarController.toolbar; toolbarController.ensureCommandsItem(); toolbarController.refresh()
        window.onKey = { [weak model] in model?.handleKey($0, editing: $1) ?? false }
        window.onCancelKeyboardFocus = { [weak self] in self?.cancelDeferredFocus() }
        window.onSidebarKey = { [weak self] in self?.splitController.sidebar.performKeyboardEntry($0) ?? false }
        model.onFocusNextPane = { [weak self] in self?.cycleKeyboardPane(reverse: false) }
        model.onFocusPreviousPane = { [weak self] in self?.cycleKeyboardPane(reverse: true) }
        model.onInspectorFocusRequested = { [weak self] in self?.focusInspector() }
        model.onFinishEditor = { [weak self] in self?.finishInspectorEditing() ?? false }
        model.onNewFolderRequested = { [weak self] in self?.createFolder() }
        model.onEditPreviewRequested = { [weak self] action, id in _ = self?.performPreviewAction(action, id: id) }
        if store.defaults === UserDefaults.standard {
            if !window.setFrameUsingName("ClipboardLineLibrary") { window.center() }
            window.setFrameAutosaveName("ClipboardLineLibrary")
        } else {
            window.center()
        }
        model.onPreview = { [weak self] in self?.previews.show($0) }
        model.onTagRequested = { [weak self] in self?.promptTag() }
        model.onPinToFolderRequested = { [weak self] ids in self?.pinToFolder(ids) }
        model.onNameAndPinRequested = { [weak self] id in self?.nameAndPin(id) }
        model.onNameAndPinBatchRequested = { [weak self] ids in self?.nameAndPin(ids) }
        model.onExportRequested = { [weak self] in self?.exportSelection() }
        model.onTrashRequested = { [weak self] in self?.confirmTrash() }
        model.onCloseRequested = { [weak self] in
            guard let window = self?.window else { return }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window.performClose(nil) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        closingFullscreen = false
        NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        model.resumeUpdates()
        // Opening the library always returns to its normal window. Full screen
        // remains an explicit macOS window action rather than a startup mode.
        model.store.defaults.set(false, forKey: "libraryFullscreen")
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        _ = model.focusContent()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.flushEdits(), previews.flush() else { return false }
        closingFullscreen = sender.styleMask.contains(.fullScreen)
        model.store.defaults.set(closingFullscreen, forKey: "libraryFullscreen"); return true
    }
    func windowWillClose(_ notification: Notification) { cancelDeferredFocus(); window?.makeFirstResponder(nil); pinFolderPicker?.window.close(); tagPicker?.window.close(); nameAndPinPicker?.window.close(); previews.close(); model.suspendUpdates() }
    func windowDidEnterFullScreen(_ notification: Notification) { model.store.defaults.set(true, forKey: "libraryFullscreen") }
    func windowDidExitFullScreen(_ notification: Notification) { if !closingFullscreen { model.store.defaults.set(false, forKey: "libraryFullscreen") } }
    func toggleFullscreen() { window?.toggleFullScreen(nil) }
    enum KeyboardPane: String, CaseIterable { case sidebar, content, inspector, search }
    var keyboardPane: KeyboardPane {
        if splitController.isSidebarFocused { return .sidebar }
        if let responder = window?.firstResponder, splitController.inspectorFocusContains(responder) { return .inspector }
        let search = toolbarController.searchField
        if window?.firstResponder === search || (search.currentEditor() != nil && window?.firstResponder === search.currentEditor()) { return .search }
        return .content
    }
    private func cancelDeferredFocus() { focusGeneration += 1; (window as? LibraryNativeWindow)?.cancelToolbarSearchFocus(); model.cancelContentFocus() }
    func cycleKeyboardPane(reverse: Bool) {
        guard model.flushEdits() else { return }
        cancelDeferredFocus()
        let panes = KeyboardPane.allCases.filter { pane in
            if pane == .sidebar { return !splitController.splitViewItems[0].isCollapsed }
            if pane == .inspector { return model.inspectorVisible && model.inspected != nil }
            return true
        }
        guard !panes.isEmpty else { return }
        let current = panes.firstIndex(of: keyboardPane) ?? (reverse ? 0 : panes.count - 1)
        let next = (current + (reverse ? -1 : 1) + panes.count) % panes.count
        focusKeyboardPane(panes[next])
    }
    func focusKeyboardPane(_ pane: KeyboardPane) {
        guard model.flushEdits() else { return }
        cancelDeferredFocus()
        switch pane {
        case .sidebar: _ = splitController.focusSidebar()
        case .content: _ = model.focusContent()
        case .inspector: focusInspector()
        case .search: model.onSearchFocus?()
        }
    }
    private func focusInspector() {
        guard model.flushEdits() else { return }
        cancelDeferredFocus(); model.inspectorVisible = true
        if splitController.focusInspector() { return }
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.focusGeneration, self.window?.isKeyWindow == true else { return }
            _ = self.splitController.focusInspector()
        }
    }
    private func finishInspectorEditing() -> Bool {
        guard let responder = window?.firstResponder, splitController.inspectorFocusContains(responder) else { return false }
        if let editor = responder as? NSTextView, editor.hasMarkedText() { return false }
        guard model.flushEdits() else { return true }
        _ = model.focusContent(); return true
    }
    func revealItemDetails(_ id: UUID) { model.revealItemDetails(id) }
    /// Preserve the chosen record when opening a command from a preview instead
    /// of reading the Library's possibly different multi-selection afterwards.
    @discardableResult func performPreviewAction(_ action: KeyboardAction, id: UUID? = nil) -> Bool {
        if action == .close { guard previews.currentID != nil else { return false }; previews.close(); return true }
        guard let target = id ?? previews.currentID ?? model.focusedID else { return false }
        if previews.currentID != target { previews.show(target) }
        guard previews.currentID == target else { return false }
        switch action {
        case .editText:
            guard let text = previews.text else { return false }; text.beginEditing(); return true
        case .finishEditing:
            if let text = previews.text { return text.finishEditing() }
            return previews.image?.performMarkupCommand(.finishEditing) ?? false
        case .preview: return true
        default: return previews.image?.perform(action) ?? false
        }
    }
    @discardableResult func performPreviewNavigation(_ action: KeyboardAction) -> Bool { previews.performNavigation(action) }
    @discardableResult func performMarkupCommand(_ command: ImageMarkupCommand, id: UUID? = nil) -> Bool {
        guard let target = id ?? previews.currentID ?? model.focusedID else { return false }
        if previews.currentID != target { previews.show(target) }
        guard previews.currentID == target else { return false }
        return previews.image?.performMarkupCommand(command) ?? false
    }
    func createFolder(parent: UUID? = nil) {
        prompt(L("New folder"), initial: "") { [weak self] name in
            guard let self else { return }; self.model.perform { _ = try self.model.store.createCollection(name, parent: parent) }
        }
    }
    func renameFolder(_ folder: LibraryCollection) {
        prompt(L("Rename folder"), initial: folder.name) { [weak self] name in
            guard let self else { return }; self.model.perform { try self.model.store.renameCollection(folder.id, name: name) }
        }
    }
    func removeFolder(_ folder: LibraryCollection) {
        let alert = NSAlert(); alert.messageText = L("Remove this folder?"); alert.informativeText = L("Its contents stay in your library.")
        alert.addButton(withTitle: L("Remove folder")); alert.addButton(withTitle: L("Cancel"))
        presentAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.model.perform { try self.model.store.removeCollection(folder.id) }; self.model.changeScope(.saved)
        }
    }
    func renameTag(_ tag: LibraryTag) {
        prompt(L("Rename tag"), initial: tag.name) { [weak self] name in
            guard let self else { return }; self.model.perform { try self.model.store.renameTag(tag.id, name: name) }
        }
    }
    func removeTag(_ tag: LibraryTag) {
        let alert = NSAlert(); alert.messageText = L("Remove this tag?"); alert.informativeText = L("Its contents stay in your library.")
        alert.addButton(withTitle: L("Remove tag")); alert.addButton(withTitle: L("Cancel"))
        presentAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.model.perform { try self.model.store.removeTag(tag.id) }; self.model.changeScope(.saved)
        }
    }
    func reportActionStatus(_ message: String) {
        model.report(message)
        previews.reportActionStatus(message)
    }
    func promptTag(ids: [UUID]? = nil) {
        guard model.flushEdits(), previews.flush() else { return }; let snapshot = ids ?? keyboardActionIDs
        guard !snapshot.isEmpty else { return }
        if let tagPicker { tagPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = previewWindow?.isKeyWindow == true ? previewWindow : window
            let picker = try TagPicker(store: model.store, ids: snapshot); tagPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforePreviewMouseKeyFocus?() }
            picker.onClose = { [weak self, weak parent] in self?.tagPicker = nil; if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) } }
            picker.show(relativeTo: parent)
        } catch { model.report(error.localizedDescription) }
    }
    private func pinToFolder(_ ids: [UUID]) {
        guard model.flushEdits(), previews.flush(), !ids.isEmpty else { return }
        if let pinFolderPicker { pinFolderPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = previewWindow?.isKeyWindow == true ? previewWindow : window
            let picker = try PinFolderPicker(store: model.store, ids: ids); pinFolderPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforePreviewMouseKeyFocus?() }
            picker.onClose = { [weak self, weak parent] in self?.pinFolderPicker = nil; if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) } }
            picker.show(relativeTo: parent)
        } catch { model.report(error.localizedDescription) }
    }
    func nameAndPin(_ id: UUID) { nameAndPin([id]) }
    func nameAndPin(_ ids: [UUID]) {
        guard !ids.isEmpty, model.flushEdits(), previews.flush() else { return }
        if let nameAndPinPicker { nameAndPinPicker.window.makeKeyAndOrderFront(nil); return }
        do {
            let parent = previewWindow?.isKeyWindow == true ? previewWindow : window
            let picker = try NameAndPinPicker(store: model.store, ids: ids); nameAndPinPicker = picker
            picker.window.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforePreviewMouseKeyFocus?() }
            if ids.count > 1 {
                picker.onAdvance = { [weak self] id in _ = self?.model.select(id, preservingSelection: true) }
                _ = model.select(picker.id, preservingSelection: true)
            }
            picker.onClose = { [weak self, weak parent] in
                self?.nameAndPinPicker = nil
                if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
            }
            picker.show(relativeTo: parent)
        } catch { model.report(error.localizedDescription) }
    }
    private func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
    private func prompt(_ title: String, initial: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26); alert.accessoryView = field
        alert.addButton(withTitle: L("Save")).keyEquivalent = "\r"
        alert.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        presentAlert(alert) { response in if response == .alertFirstButtonReturn { completion(field.stringValue) } }
    }
    func confirmTrash(ids: [UUID]? = nil) {
        guard model.flushEdits() else { return }; let snapshot = ids ?? model.actionIDs; guard !snapshot.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = String(format: L("Move %d items to recoverable Trash?"), snapshot.count)
        alert.informativeText = L("You can restore them from Library → Trash. Original files stay in place.")
        alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
        presentAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.flush() else { return }; self.model.trashSelection(snapshot)
        }
    }
    func exportSelection(ids: [UUID]? = nil) {
        guard model.flushEdits() else { return }
        let snapshot = ids ?? model.actionIDs; guard !snapshot.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = L("Export copies")
        guard let window, window.attachedSheet == nil else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url, let self, self.flush() else { return }
            self.model.perform {
                let result = try self.model.store.files.export(LibraryTransfer.exportSources(self.model.store.records(snapshot), store: self.model.store), to: folder)
                self.model.report(String(format: L("Exported %d · failed %d"), result.copies.count, result.failed.count))
            }
        }
    }
    func flush() -> Bool { model.flushEdits() && previews.flush() }
    func dismissPreviews() { previews.close() }
    func dismissForPaste() { previews.close(); window?.close() }
}

@MainActor struct LibraryContentView: View {
    @ObservedObject var model: LibraryModel
    let line: Line
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L("Content type"), selection: Binding(get: { model.query.kind?.rawValue ?? "all" }, set: { model.setKind(LibraryKind(rawValue: $0)) })) {
                    Text(L("All")).tag("all"); Text(L("Images")).tag("image"); Text(L("Texts")).tag("text"); Text(L("Links")).tag("link")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
                Spacer(minLength: 12)
                if model.query.hasFilters {
                    Button(L("Clear filters")) { model.clearFilters() }.controlSize(.small)
                }
            }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            if model.query.scope == .recent {
                Text(historyHint).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 7)
            }
            if !model.query.tagIDs.isEmpty || model.query.days != nil || !model.query.domain.isEmpty {
                HStack {
                    Label(L("Filtered view"), systemImage: "line.3.horizontal.decrease").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.tags.filter { model.query.tagIDs.contains($0.id) }) { tag in Button("#" + tag.name + " ×") { model.toggleTagFilter(tag.id) }.controlSize(.mini) }
                    if !model.query.domain.isEmpty { Text(model.query.domain).font(.caption).lineLimit(1) }
                    Spacer()
                }.padding(.horizontal, 20).padding(.vertical, 6)
            }
            ZStack {
                if model.listMode { LibraryList(model: model) } else { LibraryGrid(model: model, line: line) }
                if model.ids.isEmpty && !model.loading {
                    VStack(spacing: 12) {
                        Image(systemName: model.query.scope == .trash ? "trash" : "square.stack.3d.up").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                        Text(model.query.hasFilters ? L("No matching items") : L("Nothing here yet")).font(.title3.weight(.semibold))
                        Text(model.query.scope == .saved && !model.query.hasFilters ? L("Favorite an item, or add a folder or tag to keep it here.") : L("Try another filter or view your recent copies."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 290)
                        if model.query.hasFilters { Button(L("Clear filters")) { model.clearFilters() } }
                        else if model.query.scope == .saved { Button(L("View recent copies")) { model.changeScope(.recent) } }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if model.loading { ProgressView().controlSize(.mini); Text(L("Loading…")) }
                else { Text(String(format: L("%d items"), model.ids.count)) }
                if !model.selectedIDs.isEmpty { Text("· " + String(format: L("%d selected"), model.selectedIDs.count)) }
                Spacer()
                if !model.imageSearchStatus.isEmpty { Text(model.imageSearchStatus).lineLimit(1) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            if let notice = model.notice ?? model.store.notice {
                HStack { Text(notice); Spacer(); Button(L("Dismiss")) { model.clearNotice() } }.font(.caption).padding(10).background(.regularMaterial)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var historyHint: String {
        if let kind = model.query.kind { return String(format: L("Unsaved copies are kept for %d days"), line.retentionDays(for: kind)) }
        return LibraryKind.allCases.map { kind in (kind == .image ? L("Images") : kind == .text ? L("Texts") : L("Links")) + ": " + String(format: L("Keep for %d days"), line.retentionDays(for: kind)) }.joined(separator: " · ")
    }
}

@MainActor struct LibraryFiltersView: View {
    @ObservedObject var model: LibraryModel
    @State private var domain = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Filters")).font(.headline)
            Picker(L("Search in"), selection: Binding(get: { model.query.searchMode }, set: { model.setSearchMode($0) })) {
                Text(L("Text and visual content")).tag(LibraryQuery.SearchMode.all)
                Text(L("Text only (including OCR)")).tag(LibraryQuery.SearchMode.text)
                Text(L("Visual content only")).tag(LibraryQuery.SearchMode.visual)
            }
            Text(L("Image text is read locally. Describe images in English for best visual matches.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Added"), selection: Binding(get: { model.query.days ?? 0 }, set: { model.setDays($0 == 0 ? nil : $0) })) {
                Text(L("Any time")).tag(0); Text(L("Last 7 days")).tag(7); Text(L("Last 30 days")).tag(30)
            }
            TextField(L("Domain, e.g. youtube.com"), text: $domain).onSubmit { model.setDomain(domain) }
            Button(L("Apply domain")) { model.setDomain(domain) }
            if !model.tags.isEmpty {
                Text(L("Tags (match all)")).font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading) { ForEach(model.tags) { tag in Toggle("#" + tag.name, isOn: Binding(get: { model.query.tagIDs.contains(tag.id) }, set: { _ in model.toggleTagFilter(tag.id) })) } } }.frame(maxHeight: 150)
            }
            Button(L("Clear filters")) { model.clearFilters(); domain = "" }
        }.onAppear { domain = model.query.domain }
    }
    // Reopening the popover reflects a domain changed elsewhere or cleared.
}

@MainActor struct LibraryInspectorView: View {
    @ObservedObject var model: LibraryModel
    weak var actions: LibraryWindowController?
    @ViewBuilder var body: some View {
        if model.selectedIDs.count > 1 {
            VStack(alignment: .leading, spacing: 18) {
                Text(String(format: L("%d selected"), model.selectedIDs.count)).font(.title3.weight(.semibold))
                HStack { Button(L("Copy")) { model.copy() }; Button(L("Pin favorite")) { model.favorite() } }
                Divider()
                Menu(L("Add to folder")) { ForEach(model.collections) { folder in Button(folder.name) { model.assign(folder.id) } } }.disabled(model.collections.isEmpty)
                Button(L("Add tag…")) { actions?.promptTag() }
                Button(L("Save to library")) { model.retain() }
                Button(L("Export copies…")) { actions?.exportSelection() }
                if model.query.scope == .trash { Button(L("Restore")) { model.restore() } }
                else { Button(L("Move to Trash…")) { actions?.confirmTrash() } }
                Spacer()
            }.controlSize(.small).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        } else if let record = model.inspected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Label(record.kind == .text ? L("Text") : record.kind == .image ? L("Image") : L("Link"), systemImage: record.kind == .image ? "photo" : record.kind == .text ? "text.alignleft" : "link").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { model.onPreview?(record.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L("Preview")) }
                    TextField(record.displayTitle.isEmpty ? L("Title") : record.displayTitle, text: $model.draftTitle, axis: .vertical).font(.system(size: 16, weight: .semibold)).textFieldStyle(.plain).accessibilityLabel(L("Title")).accessibilityIdentifier("library-detail-name")
                    if record.kind == .text {
                        VStack(alignment: .leading, spacing: 7) { Text(L("Text")).font(.caption).foregroundStyle(.secondary); TextEditor(text: $model.draftText).font(.system(size: 13)).scrollContentBackground(.hidden).frame(minHeight: 150, maxHeight: 260).padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(L("Text")).accessibilityIdentifier("library-detail-text") }
                    }
                    if let url = record.linkURL {
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L("Open in browser")) { NSWorkspace.shared.open(url) }
                        if record.metadataState == "failed" { Text(L("Preview unavailable; your link is saved")).font(.caption).foregroundStyle(.secondary) }
                        Button(L("Refresh link preview")) { actions?.onRefreshLink?(record.id) }.controlSize(.small)
                    }
                    if record.kind == .image { Button(L("Open file")) { model.open() } }
                    HStack { Button(L("Copy")) { model.copy() }; Button(record.favorite ? L("Unpin") : L("Pin favorite")) { model.favorite() } }.controlSize(.small)
                    if record.deletedAt == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let uploadedURL = record.uploadedURL {
                                Text(uploadedURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            HStack {
                                Button(record.uploadedURL != nil ? L("Copy public link") : L("Upload to R2")) { model.uploadCurrent(record.id) }
                                if record.uploadedURL != nil {
                                    Button(L("Upload again to R2")) { model.uploadCurrent(record.id, forceReupload: true) }
                                }
                            }.controlSize(.small)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Folders")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.inspectedCollections) { folder in HStack { Label(folder.name, systemImage: "folder").font(.caption); Spacer(); Button { model.unassign(folder.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Remove from folder") + ": " + folder.name).accessibilityLabel(L("Remove from folder") + ": " + folder.name) } }
                        Menu(L("Add to folder")) { ForEach(model.collections) { folder in Button(folder.name) { model.assign(folder.id) } } }.disabled(model.collections.isEmpty)
                        if case .collection = model.query.scope { Menu(L("Move to folder")) { ForEach(model.collections) { folder in Button(folder.name) { model.assign(folder.id, moving: true) } } } }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Tags")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.inspectedTags) { tag in HStack { Text("#" + tag.name).font(.caption); Spacer(); Button { model.removeTag(tag.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Remove tag") + ": " + tag.name).accessibilityLabel(L("Remove tag") + ": " + tag.name) } }
                        Button(L("Add tag…")) { actions?.promptTag() }.controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 7) { Text(L("Note")).font(.caption.weight(.semibold)).foregroundStyle(.secondary); TextEditor(text: $model.draftNote).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 100).padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(L("Note")).accessibilityIdentifier("library-detail-note") }
                    Text(record.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    if record.deletedAt != nil { Button(L("Restore")) { model.restore() } }
                    else {
                        if record.retainedAt == nil { Button(L("Save to library")) { model.retain() } }
                        Button(L("Export copies…")) { actions?.exportSelection() }
                        Button(L("Move to Trash…")) { actions?.confirmTrash() }
                    }
                }.padding(20)
            }
        } else {
            VStack(spacing: 12) { Image(systemName: "sidebar.right").font(.system(size: 28, weight: .light)); Text(L("Select an item to view its details")).font(.caption).multilineTextAlignment(.center) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
        }
    }
}
