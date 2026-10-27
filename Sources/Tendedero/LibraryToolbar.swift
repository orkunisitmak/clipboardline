import AppKit
import Combine
import SwiftUI

@MainActor final class LibraryToolbarController: NSObject, NSToolbarDelegate {
    static let sidebarID = NSToolbarItem.Identifier("LibrarySidebar")
    static let dividerID = NSToolbarItem.Identifier("LibraryDivider")
    static let noteID = NSToolbarItem.Identifier("LibraryNewNote")
    static let pinID = NSToolbarItem.Identifier("LibraryPin")
    static let viewID = NSToolbarItem.Identifier("LibraryViewMode")
    static let filterID = NSToolbarItem.Identifier("LibraryFilters")
    static let sortID = NSToolbarItem.Identifier("LibrarySort")
    static let actionsID = NSToolbarItem.Identifier("LibraryActions")
    static let commandID = NSToolbarItem.Identifier("LibraryCommands")
    static let searchID = NSToolbarItem.Identifier("LibrarySearch")
    static let inspectorID = NSToolbarItem.Identifier("LibraryInspector")
    static let fullScreenID = NSToolbarItem.Identifier("LibraryFullScreen")
    let toolbar = NSToolbar(identifier: "ClipboardLineLibraryToolbar")
    let searchField: LibrarySearchTextField
    private let model: LibraryModel
    private weak var actions: LibraryWindowController?
    private weak var split: LibrarySplitController?
    private var subscription: AnyCancellable?
    private var refreshPending = false
    private var popover: NSPopover?
    private struct MenuState: Equatable {
        let sort: LibraryQuery.Sort
        let hasSelection: Bool
        let singleSelection: Bool
        let uploaded: Bool
        let trash: Bool
        let pinnedOnly: Bool
        let folders: [LibraryCollection]
    }
    private var menuState: MenuState?
    init(model: LibraryModel, actions: LibraryWindowController, split: LibrarySplitController) {
        self.model = model; self.actions = actions; self.split = split
        searchField = LibrarySearchTextField(model: model)
        super.init()
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = model.store.defaults === UserDefaults.standard
        model.onSearchFocus = { [weak self] in self?.focusSearch() }
        subscription = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshPending else { return }; self.refreshPending = true
            DispatchQueue.main.async { [weak self] in self?.refreshPending = false; self?.refresh() }
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID, Self.dividerID, Self.noteID, Self.pinID, Self.viewID, Self.filterID, Self.sortID, Self.actionsID, Self.commandID, .flexibleSpace, Self.searchID, Self.inspectorID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [Self.fullScreenID, .space] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.dividerID, let split { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0) }
        if id == Self.searchID {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            // AppKit also requests a palette prototype during customization.
            // Sharing the live view there moves it out of the window toolbar.
            if flag { item.searchField = searchField }
            else { item.searchField.placeholderString = L("Search this view") }
            item.preferredWidthForSearchField = 260
            item.label = L("Search this view"); item.toolTip = L("Search this view")
            return item
        }
        if id == Self.viewID {
            let item = NSToolbarItemGroup(itemIdentifier: id, images: [symbol("square.grid.2x2"), symbol("list.bullet")], selectionMode: .selectOne, labels: [L("Grid"), L("List")], target: self, action: #selector(changeView(_:)))
            item.label = L("View"); item.selectedIndex = model.listMode ? 1 : 0
            return item
        }
        if id == Self.sortID || id == Self.actionsID {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = id == Self.sortID ? L("Sort") : L("More")
            item.image = symbol(id == Self.sortID ? "arrow.up.arrow.down" : "ellipsis.circle")
            item.menu = id == Self.sortID ? sortMenu() : actionsMenu()
            item.toolTip = item.label; item.isBordered = true; return item
        }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.autovalidates = false; item.isBordered = true
        switch id {
        case Self.sidebarID: item.label = L("Toggle sidebar"); item.image = symbol("sidebar.left"); item.action = #selector(toggleSidebar)
        case Self.noteID: item.label = L("New note"); item.image = symbol("square.and.pencil"); item.action = #selector(newNote)
        case Self.pinID: item.label = L("Pin favorite"); item.image = symbol("pin"); item.action = #selector(pin)
        case Self.commandID: item.label = L("Actions"); item.image = symbol("command"); item.action = #selector(showCommands)
        case Self.filterID:
            item.label = L("Filters")
            let button = NSButton(image: symbol("line.3.horizontal.decrease"), target: self, action: #selector(showFilters(_:)))
            button.bezelStyle = .texturedRounded; button.setAccessibilityLabel(L("Filters")); button.toolTip = L("Filters")
            item.view = button
            item.menuFormRepresentation = ClosureMenuItem(L("Filters")) { [weak self] in self?.presentFilters(relativeTo: nil) }
        case Self.inspectorID: item.label = L("Show details"); item.image = symbol("sidebar.right"); item.action = #selector(toggleInspector)
        case Self.fullScreenID: item.label = L("Toggle full screen"); item.image = symbol("arrow.up.left.and.arrow.down.right"); item.action = #selector(toggleFullscreen)
        default: return nil
        }
        item.toolTip = id == Self.commandID ? commandsHint : item.label; return item
    }
    private func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil)! }
    func refresh() {
        guard let window = actions?.window else { return }
        if window.title != model.title { window.title = model.title }
        let subtitle = model.loading ? L("Loading…") : String(format: L("%d items"), model.ids.count)
        if window.subtitle != subtitle { window.subtitle = subtitle }
        let singleID = model.actionIDs.count == 1 ? model.actionIDs.first : nil
        let uploaded = singleID.flatMap { try? model.store.item($0)?.uploadedURL } != nil
        let state = MenuState(sort: model.query.sort, hasSelection: !model.selectedIDs.isEmpty || model.focusedID != nil, singleSelection: singleID != nil, uploaded: uploaded, trash: model.query.scope == .trash, pinnedOnly: model.showingPinnedOnly, folders: model.collections)
        let menusChanged = menuState != state; menuState = state
        if searchField.stringValue != model.search { searchField.stringValue = model.search }
        for item in toolbar.items {
            if let group = item as? NSToolbarItemGroup { group.selectedIndex = model.listMode ? 1 : 0 }
            if item.itemIdentifier == Self.pinID {
                item.isEnabled = !model.selectedIDs.isEmpty || model.focusedID != nil
                let pinned = model.selectedIDs.count <= 1 && model.inspected?.favorite == true
                item.image = symbol(pinned ? "pin.fill" : "pin"); item.toolTip = (pinned ? L("Unpin") : L("Pin favorite")) + " · " + model.keyboardBindings.title(.pin)
            }
            if item.itemIdentifier == Self.filterID { (item.view as? NSButton)?.image = symbol(model.query.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") }
            if item.itemIdentifier == Self.inspectorID { item.label = model.inspectorVisible ? L("Hide details") : L("Show details"); item.toolTip = item.label }
            if item.itemIdentifier == Self.commandID { item.toolTip = commandsHint }
            if menusChanged, let menu = item as? NSMenuToolbarItem { menu.menu = item.itemIdentifier == Self.sortID ? sortMenu() : actionsMenu() }
        }
    }
    private var commandsHint: String {
        let hint = model.keyboardBindings.title(.commandPalette)
        return L("Actions") + (hint.isEmpty ? "" : " · " + hint)
    }
    /// Native toolbar configuration is restored by AppKit. New installations
    /// include Commands by default; existing layouts receive its discoverable
    /// entry once without discarding their customized items.
    func ensureCommandsItem() {
        guard !toolbar.items.contains(where: { $0.itemIdentifier == Self.commandID }) else { return }
        let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.actionsID }).map { $0 + 1 } ?? toolbar.items.count
        toolbar.insertItem(withItemIdentifier: Self.commandID, at: index)
    }
    private func focusSearch() {
        if !toolbar.items.contains(where: { $0.itemIdentifier == Self.searchID }) { toolbar.insertItem(withItemIdentifier: Self.searchID, at: toolbar.items.count) }
        if searchField.stringValue != model.search { searchField.stringValue = model.search }
        (actions?.window as? LibraryNativeWindow)?.beginToolbarSearchFocus(for: searchField)
        (toolbar.items.first(where: { $0.itemIdentifier == Self.searchID }) as? NSSearchToolbarItem)?.beginSearchInteraction()
        searchField.selectText(nil)
    }
    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        let choices: [(LibraryQuery.Sort, String)] = [(.newest, L("Newest first")), (.oldest, L("Oldest first")), (.title, L("Title")), (.titleDescending, L("Title, Z–A")), (.copied, L("Last copied")), (.relevance, L("Best match"))]
        for (sort, title) in choices {
            let item = ClosureMenuItem(title) { [weak model] in model?.setSort(sort) }; item.state = model.query.sort == sort ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    private func actionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title, handler: action); item.isEnabled = enabled; menu.addItem(item)
        }
        let hasSelection = !model.selectedIDs.isEmpty || model.focusedID != nil
        add(L("Copy"), enabled: hasSelection) { [weak model] in model?.copy() }
        if model.query.scope != .trash {
            let singleID = model.actionIDs.count == 1 ? model.actionIDs.first : nil
            let hasUploaded = singleID.flatMap { try? model.store.item($0)?.uploadedURL } != nil
            add(hasUploaded ? L("Copy public link") : L("Upload to R2"), enabled: singleID != nil) { [weak model] in model?.uploadCurrent() }
            if hasUploaded {
                add(L("Upload again to R2"), enabled: true) { [weak model] in model?.uploadCurrent(forceReupload: true) }
            }
        }
        add(L("Save to library"), enabled: hasSelection) { [weak model] in model?.retain() }
        add(L("Show pinned items")) { [weak model] in model?.togglePinnedOnly() }
        menu.items.last?.state = model.showingPinnedOnly ? .on : .off
        if !model.collections.isEmpty {
            let folders = NSMenu()
            for folder in model.collections { folders.addItem(ClosureMenuItem(folder.name) { [weak model] in model?.assign(folder.id) }) }
            let item = NSMenuItem(title: L("Add to folder"), action: nil, keyEquivalent: ""); item.submenu = folders; item.isEnabled = hasSelection; menu.addItem(item)
        }
        add(L("Add tag…"), enabled: hasSelection) { [weak actions] in actions?.promptTag() }
        add(L("Export copies…"), enabled: hasSelection) { [weak actions] in actions?.exportSelection() }
        menu.addItem(.separator())
        if model.query.scope == .trash { add(L("Restore"), enabled: hasSelection) { [weak model] in model?.restore() } }
        else { add(L("Move to Trash…"), enabled: hasSelection) { [weak actions] in actions?.confirmTrash() } }
        menu.addItem(.separator()); add(L("New folder")) { [weak actions] in actions?.createFolder() }
        return menu
    }
    @objc private func toggleSidebar() { split?.toggleSidebar(nil) }
    @objc private func toggleInspector() { model.inspectorVisible.toggle() }
    @objc private func toggleFullscreen() { actions?.toggleFullscreen() }
    @objc private func newNote() { model.newNote() }
    @objc private func pin() { model.favorite() }
    @objc private func showCommands() { model.onCommandsRequested?() }
    @objc private func changeView(_ sender: NSToolbarItemGroup) { model.listMode = sender.selectedIndex == 1 }
    @objc private func showFilters(_ sender: NSButton) {
        presentFilters(relativeTo: sender)
    }
    func presentFilters(relativeTo button: NSView?) {
        guard let anchor = button ?? actions?.window?.contentView else { return }
        if popover?.isShown == true { popover?.close(); return }
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LibraryFiltersView(model: model).padding(20).frame(width: 330))
        let rect = button != nil ? anchor.bounds : NSRect(x: anchor.bounds.maxX - 24, y: anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1, width: 1, height: 1)
        self.popover = popover; popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }
}
