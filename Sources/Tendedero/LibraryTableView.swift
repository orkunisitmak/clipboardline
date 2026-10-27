import AppKit
import Combine
import SwiftUI

struct LibraryList: NSViewControllerRepresentable {
    let model: LibraryModel
    func makeNSViewController(context: Context) -> LibraryTableController { LibraryTableController(model: model) }
    func updateNSViewController(_ controller: LibraryTableController, context: Context) { controller.enqueueRefresh() }
}

private final class LibraryNativeTable: NSTableView {
    var libraryKeyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self, libraryKeyHandler?(event) == true || LibraryContentKeyRouting.ownsDefault(event) { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, libraryKeyHandler?(event) == true || LibraryContentKeyRouting.ownsDefault(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    var contextualMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextualMenu?(row(at: convert(event.locationInWindow, from: nil))) }
}

@MainActor final class LibraryTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: LibraryModel
    private let nativeTable = LibraryNativeTable()
    var table: NSTableView { nativeTable }
    private let scroll = NSScrollView()
    private let thumbnails = ThumbnailStore()
    private var subscription: AnyCancellable?
    private var previousIDs = [UUID]()
    private var previousSelection = Set<UUID>()
    private var previousCopies = Set<UUID>()
    private var recordsDirty = true
    private var pending = false
    private var refreshing = false
    private var dragWriters = [UUID: NSPasteboardWriting]()
    private var dragEvent: Int?
    private var dragSelection = Set<UUID>()
    private var pendingRevealID: UUID?
    init(model: LibraryModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = scroll; scroll.documentView = nativeTable
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.contentView.postsBoundsChangedNotifications = true
        nativeTable.style = .fullWidth; nativeTable.rowHeight = 52; nativeTable.intercellSpacing = NSSize(width: 10, height: 0)
        nativeTable.usesAlternatingRowBackgroundColors = true; nativeTable.allowsMultipleSelection = true
        nativeTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        nativeTable.autosaveName = "ClipboardLineLibraryListColumns"; nativeTable.autosaveTableColumns = true
        for (key, title, width, minimum) in [("title", L("Title"), 300.0, 180.0), ("kind", L("Content type"), 80, 70), ("tags", L("Tags"), 150, 80), ("created", L("Added"), 130, 100)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = minimum
            if key == "title" || key == "created" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "title") }
            nativeTable.addTableColumn(column)
        }
        nativeTable.dataSource = self; nativeTable.delegate = self; nativeTable.target = self; nativeTable.doubleAction = #selector(previewRow)
        nativeTable.libraryKeyHandler = { [weak model] in model?.handleKey($0, editing: false) ?? false }
        nativeTable.setAccessibilityLabel(L("Library") + " · " + L("List"))
        nativeTable.setDraggingSourceOperationMask(.copy, forLocal: true); nativeTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        nativeTable.contextualMenu = { [weak self] in self?.menu(for: $0) }
        thumbnails.onLoad = { [weak self] in self?.recordsDirty = true; self?.enqueueRefresh() }
        model.thumbnailStats = { [weak self] in self?.thumbnails.stats }
        model.onRecordsChanged = { [weak self] _ in self?.recordsDirty = true; self?.enqueueRefresh() }
        model.onContentFocus = { [weak self] in _ = self?.focusContent() }
        model.onContentFocusReady = { [weak self] in self?.focusContent() ?? false }
        model.onSelectionReveal = { [weak self] id in
            self?.pendingRevealID = id
            self?.revealPendingSelection()
        }
        subscription = model.objectWillChange.sink { [weak self] _ in self?.enqueueRefresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        refresh()
    }
    @discardableResult func focusContent() -> Bool {
        guard let window = view.window else { return false }
        pendingRevealID = model.focusedID; revealPendingSelection()
        return window.makeFirstResponder(nativeTable)
    }
    private func revealPendingSelection() {
        guard let id = pendingRevealID else { return }
        guard model.focusedID == id else { pendingRevealID = nil; return }
        // Query IDs may arrive before NSTableView reloads its old row count.
        guard previousIDs == model.ids, let row = model.index(of: id), row < nativeTable.numberOfRows else { return }
        pendingRevealID = nil; nativeTable.scrollRowToVisible(row)
    }
    func enqueueRefresh() {
        guard !pending else { return }; pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.refresh() }
    }
    override func viewDidAppear() { super.viewDidAppear(); model.finishContentFocus() }
    override func viewDidLayout() { super.viewDidLayout(); requestVisible() }
    private var visibleRows: IndexSet {
        let range = nativeTable.rows(in: scroll.documentVisibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return IndexSet(integersIn: range.location..<min(model.ids.count, NSMaxRange(range)))
    }
    private func refresh() {
        guard isViewLoaded else { return }; refreshing = true; defer { refreshing = false }
        model.columns = 1
        if previousIDs != model.ids { previousIDs = model.ids; nativeTable.reloadData(); recordsDirty = true }
        let selection = IndexSet(model.selectedIDs.compactMap { model.index(of: $0) })
        if nativeTable.selectedRowIndexes != selection { nativeTable.selectRowIndexes(selection, byExtendingSelection: false) }
        revealPendingSelection()
        if recordsDirty || previousSelection != model.selectedIDs || previousCopies != model.copiedIDs {
            nativeTable.reloadData(forRowIndexes: visibleRows, columnIndexes: IndexSet(integersIn: 0..<nativeTable.numberOfColumns))
            previousSelection = model.selectedIDs; previousCopies = model.copiedIDs; recordsDirty = false
        }
        let sort: NSSortDescriptor?
        switch model.query.sort { case .newest: sort = NSSortDescriptor(key: "created", ascending: false); case .oldest: sort = NSSortDescriptor(key: "created", ascending: true); case .title: sort = NSSortDescriptor(key: "title", ascending: true); case .titleDescending: sort = NSSortDescriptor(key: "title", ascending: false); default: sort = nil }
        let descriptors = sort.map { [$0] } ?? []
        if nativeTable.sortDescriptors != descriptors { nativeTable.sortDescriptors = descriptors }
        requestVisible()
    }
    @objc private func scrolled() { requestVisible() }
    private func requestVisible() {
        guard isViewLoaded else { return }
        let ids = visibleRows.compactMap { model.ids.indices.contains($0) ? model.ids[$0] : nil }
        model.requestVisible(ids.isEmpty ? Array(model.ids.prefix(80)) : ids)
        thumbnails.request(ids.compactMap { id in
            guard let record = model.summary(id) else { return nil }
            return record.kind == .image ? record.fileURL : record.thumbnailPath.map { URL(fileURLWithPath: $0) }
        }, pixels: 96)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.ids.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.ids.indices.contains(row), let column = tableColumn else { return nil }
        let id = model.ids[row], summary = model.cardSummary(id), record = summary?.record
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
        if identifier.rawValue == "title" {
            cell.textField?.stringValue = record?.displayTitle ?? L("Loading…"); cell.toolTip = record?.displayTitle
            let icon = record?.kind == .image ? "photo" : record?.kind == .link ? "link" : "doc.text"
            let url = record?.kind == .image ? record?.fileURL : record?.thumbnailPath.map { URL(fileURLWithPath: $0) }
            cell.imageView?.image = url.flatMap { thumbnails.image(for: $0, pixels: 96) } ?? NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            if let badge = cell.viewWithTag(81) as? NSImageView {
                let copied = model.copiedIDs.contains(id)
                badge.isHidden = !copied && record?.favorite != true
                badge.image = NSImage(systemSymbolName: copied ? "checkmark.circle.fill" : "pin.fill", accessibilityDescription: copied ? L("Copied") : L("Pin favorite"))
                badge.contentTintColor = copied ? .systemGreen : .controlAccentColor
            }
        } else if identifier.rawValue == "kind" { cell.textField?.stringValue = record.map { $0.kind == .image ? L("Images") : $0.kind == .text ? L("Texts") : L("Links") } ?? "" }
        else if identifier.rawValue == "tags" { cell.textField?.stringValue = summary?.tagLabel ?? ""; cell.toolTip = summary?.tagLabel }
        else { cell.textField?.stringValue = record.map { Self.dateFormatter.string(from: $0.createdAt) } ?? "" }
        return cell
    }
    private static let dateFormatter: DateFormatter = { let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none; return formatter }()
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        if identifier.rawValue == "title" {
            let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown; image.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(image); cell.imageView = image
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.widthAnchor.constraint(equalToConstant: 36), image.heightAnchor.constraint(equalToConstant: 36), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10)])
            let badge = NSImageView(); badge.tag = 81; badge.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(badge)
            NSLayoutConstraint.activate([badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor), badge.widthAnchor.constraint(equalToConstant: 13), badge.heightAnchor.constraint(equalToConstant: 13)])
        } else { label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5).isActive = true }
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: identifier.rawValue == "title" ? -26 : -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        let selected = Set(nativeTable.selectedRowIndexes.compactMap { model.ids.indices.contains($0) ? model.ids[$0] : nil })
        let focused = model.ids.indices.contains(nativeTable.selectedRow) ? model.ids[nativeTable.selectedRow] : nil
        if !model.acceptNativeSelection(selected, focused: focused) { enqueueRefresh() }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !refreshing, let descriptor = tableView.sortDescriptors.first else { return }
        model.setSort(descriptor.key == "title" ? descriptor.ascending ? .title : .titleDescending : descriptor.ascending ? .oldest : .newest)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard model.ids.indices.contains(row) else { return nil }
        let id = model.ids[row]
        // AppKit may request writers during layout or accessibility handling.
        // eventNumber is only valid for mouse events, never KitDefined events.
        let event = NSApp.currentEvent.flatMap { current -> Int? in
            [.leftMouseDown, .leftMouseDragged].contains(current.type) ? current.eventNumber : nil
        }
        if dragEvent != event || dragSelection != model.selectedIDs || dragWriters[id] == nil {
            dragEvent = event; dragWriters = Dictionary(uniqueKeysWithValues: model.dragItems(id).map { ($0.id, $0.writer) })
            dragSelection = model.selectedIDs
        }
        return dragWriters[id]
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragWriters.removeAll(); dragEvent = nil; dragSelection.removeAll() }
    @objc private func previewRow() {
        guard model.ids.indices.contains(nativeTable.clickedRow) else { return }
        let id = model.ids[nativeTable.clickedRow]; if model.select(id, preservingSelection: true) { model.onPreview?(id) }
    }
    private func menu(for row: Int) -> NSMenu? {
        guard model.ids.indices.contains(row) else { return nil }
        let id = model.ids[row]; guard model.selectedIDs.contains(id) || model.select(id) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Preview")) { [weak model] in model?.onPreview?(id) })
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak model] in model?.copy() })
        if model.query.scope != .trash && model.actionIDs.count == 1 {
            let hasUploaded = (try? model.store.item(id))?.uploadedURL != nil
            menu.addItem(ClosureMenuItem(hasUploaded ? L("Copy public link") : L("Upload to R2")) { [weak model] in model?.uploadCurrent(id) })
            if hasUploaded {
                menu.addItem(ClosureMenuItem(L("Upload again to R2")) { [weak model] in model?.uploadCurrent(id, forceReupload: true) })
            }
        }
        menu.addItem(ClosureMenuItem(L("Pin favorite")) { [weak model] in model?.favorite() })
        if model.query.scope != .trash {
            menu.addItem(ClosureMenuItem(L("Name and pin…")) { [weak model] in model?.onNameAndPinRequested?(id) })
        }
        menu.addItem(ClosureMenuItem(L("Add tag…")) { [weak model] in model?.onTagRequested?() })
        let folders = NSMenu()
        for folder in model.collections { folders.addItem(ClosureMenuItem(folder.name) { [weak model] in model?.assign(folder.id) }) }
        if !model.collections.isEmpty { let item = NSMenuItem(title: L("Add to folder"), action: nil, keyEquivalent: ""); item.submenu = folders; menu.addItem(item) }
        menu.addItem(ClosureMenuItem(L("Export copies…")) { [weak model] in model?.onExportRequested?() })
        menu.addItem(.separator())
        if model.query.scope == .trash { menu.addItem(ClosureMenuItem(L("Restore")) { [weak model] in model?.restore() }) }
        else { menu.addItem(ClosureMenuItem(L("Move to Trash…")) { [weak model] in model?.onTrashRequested?() }) }
        return menu
    }
}
