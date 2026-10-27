import AppKit
import Combine
import SwiftUI

struct LibraryGrid: NSViewControllerRepresentable {
    let model: LibraryModel
    let line: Line
    func makeNSViewController(context: Context) -> LibraryCollectionController { LibraryCollectionController(model: model, line: line) }
    func updateNSViewController(_ controller: LibraryCollectionController, context: Context) { controller.refresh() }
}

final class LibraryCollectionItem: NSCollectionViewItem {
    private var host: NSHostingView<LibraryCard>?
    fileprivate var state: LibraryCardState?
    override func prepareForReuse() { super.prepareForReuse(); state = nil }
    override func loadView() { view = NSView(); view.wantsLayer = true }
    fileprivate func configure(_ card: LibraryCard) {
        if let host { host.rootView = card }
        else {
            let host = NSHostingView(rootView: card); self.host = host
            host.sizingOptions = []; host.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.topAnchor.constraint(equalTo: view.topAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
    }
}

fileprivate struct LibraryCardState: Equatable {
    let id: UUID
    let record: LibraryRecord?
    let tags: String
    let selected: Bool
    let focused: Bool
    let image: ObjectIdentifier?
    let list: Bool
    let theme: ShelfTheme
    let copied: Bool
    let shortcuts: String
}

/// AppKit otherwise supplies type selection, arrows and Select All after an
/// app command is disabled. Only the focused results view owns these defaults;
/// inactive views must never consume an inspector's editing equivalents.
@MainActor enum LibraryContentKeyRouting {
    static func ownsDefault(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let key = KeyShortcut.capture(event, allowPlain: true) else { return false }
        return KeyboardAction.allCases.contains { action in
            action.contexts.contains(.library) && action.defaults(in: .library).contains {
                $0.keyCode == key.keyCode && $0.modifiers == key.modifiers
            }
        }
    }
}

@MainActor final class LibraryNativeCollectionView: NSCollectionView {
    var libraryKeyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self, libraryKeyHandler?(event) == true || LibraryContentKeyRouting.ownsDefault(event) { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, libraryKeyHandler?(event) == true || LibraryContentKeyRouting.ownsDefault(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class LibraryCollectionController: NSViewController, NSCollectionViewDelegate {
    let model: LibraryModel
    let line: Line
    private(set) var collection = LibraryNativeCollectionView()
    private let scroll = NSScrollView()
    private var flow = NSCollectionViewFlowLayout()
    private let thumbs = ThumbnailStore()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>!
    private var subscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?
    private var refreshing = false
    private var previousIDs = [UUID]()
    private var previousListMode = false
    private var pendingRefresh = false
    private var applyingSnapshot = false
    private var shortcutHint = ""
    private var pendingRevealID: UUID?
    private(set) var cardConfigurationCount = 0
    private(set) var refreshPassCount = 0
    init(model: LibraryModel, line: Line) { self.model = model; self.line = line; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = scroll
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        thumbs.onLoad = { [weak self] in self?.enqueueRefresh() }
        model.thumbnailStats = { [weak self] in self?.thumbs.stats }
        model.collectionStats = { [weak self] in guard let self else { return nil }; return (self.cardConfigurationCount, self.refreshPassCount) }
        subscription = model.objectWillChange.sink { [weak self] _ in self?.enqueueRefresh() }
        themeSubscription = line.$theme.dropFirst().removeDuplicates().sink { [weak self] _ in self?.enqueueRefresh() }
        model.onRecordsChanged = { [weak self] _ in self?.enqueueRefresh() }
        model.onContentFocus = { [weak self] in _ = self?.focusContent() }
        model.onContentFocusReady = { [weak self] in self?.focusContent() ?? false }
        model.onSelectionReveal = { [weak self] id in
            self?.pendingRevealID = id
            self?.revealPendingSelection()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        refresh()
    }
    /// Selection can change while the sidebar or an inspector editor owns the
    /// keyboard. Scrolling must not transfer that focus; deliberate content
    /// entry and a mouse selection use this separate route.
    @discardableResult func focusContent() -> Bool {
        guard let window = view.window else { return false }
        pendingRevealID = model.focusedID; revealPendingSelection()
        return window.makeFirstResponder(collection)
    }
    private func revealPendingSelection() {
        guard let id = pendingRevealID else { return }
        guard model.focusedID == id else { pendingRevealID = nil; return }
        guard !applyingSnapshot, previousIDs == model.ids, let dataSource, let path = dataSource.indexPath(for: id) else { return }
        pendingRevealID = nil
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
    }
    private func resetCollection() {
        // macOS can retain hosted card layers after a nonanimated diffable
        // snapshot shrinks, even when reloadData reports the new item count.
        // Start a fresh native collection at result boundaries. Stable results
        // still reuse their cells, record pages and bounded thumbnail cache.
        let hadFocus = view.window?.firstResponder === collection
        collection.delegate = nil; scroll.documentView = nil; dataSource = nil
        collection = LibraryNativeCollectionView(); flow = NSCollectionViewFlowLayout()
        collection.libraryKeyHandler = { [weak model] in model?.handleKey($0, editing: false) ?? false }
        flow.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); flow.minimumInteritemSpacing = 16; flow.minimumLineSpacing = 16
        collection.collectionViewLayout = flow; collection.backgroundColors = [.clear]
        collection.autoresizingMask = [.width]
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.delegate = self
        collection.setDraggingSourceOperationMask(.copy, forLocal: true); collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.register(LibraryCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("LibraryCard"))
        scroll.documentView = collection
        dataSource = NSCollectionViewDiffableDataSource<Int, UUID>(collectionView: collection) { [weak self] collection, path, id in
            guard let self else { return nil }
            let item = collection.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("LibraryCard"), for: path) as! LibraryCollectionItem
            self.configure(item, id: id); return item
        }
        updateLayout()
        if hadFocus { view.window?.makeFirstResponder(collection) }
    }
    override func viewDidAppear() { super.viewDidAppear(); model.finishContentFocus() }
    override func viewDidLayout() { super.viewDidLayout(); updateLayout(); visibleChanged() }
    private func enqueueRefresh() {
        guard !pendingRefresh else { return }; pendingRefresh = true
        DispatchQueue.main.async { [weak self] in self?.pendingRefresh = false; self?.refresh() }
    }
    func refresh() {
        guard isViewLoaded, !applyingSnapshot else { return }
        refreshPassCount += 1
        shortcutHint = model.keyboardBindings.hint([.copy, .upload, .pin])
        refreshing = true; defer { refreshing = false }
        updateLayout()
        if dataSource == nil || previousIDs != model.ids {
            resetCollection()
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>(); snapshot.appendSections([0]); snapshot.appendItems(model.ids)
            previousIDs = model.ids; applyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                self.applyingSnapshot = false
                self.flow.invalidateLayout(); self.refresh()
            }
            return
        }
        collection.layoutSubtreeIfNeeded()
        let height = max(scroll.contentSize.height, flow.collectionViewContentSize.height)
        if collection.frame.height != height { collection.setFrameSize(NSSize(width: scroll.contentSize.width, height: height)) }
        collection.selectionIndexPaths = Set(model.selectedIDs.compactMap { dataSource.indexPath(for: $0) })
        revealPendingSelection()
        refreshVisibleCards(); visibleChanged()
    }
    private func updateLayout() {
        let width = max(1, scroll.contentSize.width), columns = max(1, Int((width - 40 + 16) / 224))
        if collection.frame.width != width { collection.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, collection.frame.height))) }
        let size = model.listMode ? NSSize(width: max(180, width - 40), height: 86) : NSSize(width: max(160, floor((width - 40 - CGFloat(columns - 1) * 16) / CGFloat(columns))), height: 222)
        if flow.itemSize != size { flow.itemSize = size; flow.invalidateLayout() }
        model.columns = model.listMode ? 1 : columns
        previousListMode = model.listMode
    }
    private func card(_ id: UUID, image: NSImage?) -> LibraryCard {
        let summary = model.cardSummary(id), record = summary?.record
        return LibraryCard(record: record, tagLabel: summary?.tagLabel ?? "", keyboardBindings: model.keyboardBindings, selected: model.selectedIDs.contains(id), focused: model.focusedID == id,
            image: image, list: model.listMode, theme: line.theme,
            copied: model.copiedIDs.contains(id), onSelect: { [weak self] flags in
                guard let self else { return }
                // A plain drag from an existing selection must keep its peers.
                let selected: Bool
                if !flags.intersection([.command, .shift]).isEmpty || !self.model.selectedIDs.contains(id) {
                    selected = self.model.select(id, toggle: flags.contains(.command), extending: flags.contains(.shift))
                } else { selected = self.model.select(id, preservingSelection: true) }
                if selected { _ = self.focusContent() }
            }, onCopy: { [weak self] in guard let self else { return }; if self.model.selectedIDs.contains(id) || self.model.select(id) { self.model.copy() } },
            onUpload: { [weak self] in guard let self else { return }; if self.model.select(id) { self.model.uploadCurrent(id) } },
            onPin: { [weak self] in guard let self else { return }; if self.model.selectedIDs.contains(id) || self.model.select(id) { self.model.favorite() } },
            onPreview: { [weak self] in guard let self else { return }; if !self.model.selectedIDs.contains(id) { _ = self.model.select(id) }; self.model.onPreview?(id) },
            dragItems: { [weak self] in self?.model.dragItems(id) ?? [] })
    }
    func configure(_ item: LibraryCollectionItem, id: UUID) {
        let summary = model.cardSummary(id), record = summary?.record
        let url = record?.kind == .image ? record?.fileURL : record?.thumbnailPath.map { URL(fileURLWithPath: $0) }
        let image = url.flatMap { thumbs.image(for: $0, pixels: thumbnailPixels) }
        let state = LibraryCardState(id: id, record: record, tags: summary?.tagLabel ?? "", selected: model.selectedIDs.contains(id), focused: model.focusedID == id,
            image: image.map(ObjectIdentifier.init), list: model.listMode, theme: line.theme, copied: model.copiedIDs.contains(id), shortcuts: shortcutHint)
        guard item.state != state else { return }
        item.state = state; cardConfigurationCount += 1; item.configure(card(id, image: image))
    }
    private func refreshVisibleCards() {
        guard dataSource != nil, !applyingSnapshot else { return }
        for path in visiblePaths {
            guard let id = dataSource.itemIdentifier(for: path), let item = collection.item(at: path) as? LibraryCollectionItem else { continue }
            configure(item, id: id)
        }
    }
    @objc private func scrolled() { visibleChanged(); refreshVisibleCards() }
    private var thumbnailPixels: Int { min(640, max(160, Int((model.listMode ? 96 : max(1, flow.itemSize.width - 24)) * (view.window?.backingScaleFactor ?? 2)))) }
    private var visiblePaths: [IndexPath] {
        let rect = scroll.documentVisibleRect
        return collection.indexPathsForVisibleItems().filter { path in
            flow.layoutAttributesForItem(at: path)?.frame.intersects(rect) == true
        }.sorted()
    }
    private func visibleChanged() {
        guard dataSource != nil, !applyingSnapshot else { return }
        let ids = visiblePaths.compactMap { dataSource.itemIdentifier(for: $0) }
        model.requestVisible(ids.isEmpty ? Array(model.ids.prefix(80)) : ids)
        thumbs.request(ids.compactMap { id in guard let record = model.summary(id) else { return nil }; return record.kind == .image ? record.fileURL : record.thumbnailPath.map { URL(fileURLWithPath: $0) } }, pixels: thumbnailPixels)
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !refreshing, !applyingSnapshot else { return }
        let selected = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        let id = indexPaths.sorted().last.flatMap { dataSource.itemIdentifier(for: $0) }
        if model.acceptNativeSelection(selected, focused: id) { _ = focusContent() }
        else { refresh() }
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !refreshing, !applyingSnapshot else { return }
        let selected = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        if !model.acceptNativeSelection(selected, focused: model.focusedID) { refresh() }
    }
}

private struct LibraryGrabArea: NSViewRepresentable {
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPreview: () -> Void
    let dragItems: () -> [ShelfDragItem]
    func makeNSView(context: Context) -> GrabView { let view = GrabView(); configure(view); return view }
    func updateNSView(_ view: GrabView, context: Context) { configure(view) }
    private func configure(_ view: GrabView) {
        view.selectionMode = true; view.usesCornerActions = false
        view.selectsOnMouseDown = true; view.operationMask = .copy
        view.onClick = onSelect; view.onDoubleClick = onPreview; view.payloadProvider = dragItems
    }
}

private struct LibraryCard: View {
    let record: LibraryRecord?
    let tagLabel: String
    let keyboardBindings: KeyboardBindings
    let selected: Bool
    let focused: Bool
    let image: NSImage?
    let list: Bool
    let theme: ShelfTheme
    let copied: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onCopy: () -> Void
    let onUpload: () -> Void
    let onPin: () -> Void
    let onPreview: () -> Void
    let dragItems: () -> [ShelfDragItem]
    @State private var hovering = false
    private var shelf: Shelf { record?.kind == .text ? .texts : record?.kind == .link ? .links : .images }
    var body: some View {
        Group {
            if let record {
                if list {
                    HStack(spacing: 14) { media(record).frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)); title(record).padding(.trailing, 94); Spacer() }.padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        media(record).frame(maxWidth: .infinity).frame(height: 120).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        title(record)
                    }.padding(12)
                }
            } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.11) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 0.5))
            .overlay(alignment: .bottomTrailing) { if copied { Label(L("Copied"), systemImage: "checkmark").font(.caption.bold()).padding(6).background(.regularMaterial, in: Capsule()).padding(7) } }
            .onHover { hovering = $0 }
            // Native mouse handling selects immediately and starts a real,
            // multi-item file drag; a SwiftUI tap swallowed collection drags.
            .overlay(LibraryGrabArea(onSelect: onSelect, onPreview: onPreview, dragItems: dragItems))
            .overlay(alignment: list ? .trailing : .topTrailing) { if let record { actions(record).padding(list ? 10 : 17) } }
            .accessibilityElement(children: .contain).accessibilityLabel(record?.displayTitle ?? L("Loading"))
    }
    @ViewBuilder private func media(_ record: LibraryRecord) -> some View {
        ZStack(alignment: .topLeading) {
            theme.wash(shelf)
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if record.kind == .text {
                Text(record.text ?? "").font(.system(size: list ? 10 : 13)).lineLimit(list ? 3 : 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
            } else { Image(systemName: shelf.icon).font(.system(size: 30, weight: .light)).foregroundStyle(theme.accent(shelf)).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    private func title(_ record: LibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.displayTitle.isEmpty ? L("Untitled note") : record.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(list ? 1 : 2)
            HStack(spacing: 5) { Image(systemName: shelf.icon); Text(record.kind == .link ? record.author ?? record.linkURL?.host ?? shelf.title : shelf.title); if record.favorite { Image(systemName: "pin.fill").foregroundStyle(.tint) }; if record.uploadedURL != nil { Image(systemName: "link.icloud").foregroundStyle(.tint) } }
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if !tagLabel.isEmpty { Text(tagLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(tagLabel) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actions(_ record: LibraryRecord) -> some View {
        HStack(spacing: 4) {
            Button(action: onCopy) { Image(systemName: "doc.on.doc").frame(width: 23, height: 23) }.help(L("Copy") + " · " + keyboardBindings.title(.copy))
            if record.deletedAt == nil {
                Button(action: onUpload) { Image(systemName: record.uploadedURL != nil ? "link.icloud" : "icloud.and.arrow.up").foregroundStyle(record.uploadedURL != nil ? Color.accentColor : Color.primary).frame(width: 23, height: 23) }.help((record.uploadedURL != nil ? L("Copy public link") : L("Upload to R2")) + " · " + keyboardBindings.title(.upload))
            }
            Button(action: onPin) { Image(systemName: record.favorite ? "pin.fill" : "pin").foregroundStyle(record.favorite ? Color.accentColor : Color.primary).frame(width: 23, height: 23) }.help(L("Pin favorite") + " · " + keyboardBindings.title(.pin))
        }.buttonStyle(.plain).padding(3).background(.regularMaterial, in: Capsule()).opacity(hovering || focused ? 1 : 0).allowsHitTesting(hovering || focused)
    }
}
