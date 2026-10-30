import AppKit
import AVFoundation
import Combine
import Carbon
import os

let log = Logger(subsystem: "app.tendedero.Tendedero", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var thumb: NSImage?
    var pinned = false
    var managedCopy = false
    var originalPath: String?
    var title: String?
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    init(id: UUID = UUID(), url: URL, thumb: NSImage?, pinned: Bool = false, managedCopy: Bool = false, originalPath: String? = nil, title: String? = nil) {
        self.id = id; self.url = url; self.thumb = thumb; self.pinned = pinned; self.managedCopy = managedCopy; self.originalPath = originalPath
        self.title = title
    }
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { isRecordingFile(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.url == b.url && a.pinned == b.pinned && a.title == b.title && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// External originals stay in place; private clipboard copies expire.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = [] { didSet { filteredItems = nil; cachedSelectedItems = nil } }
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    private var copyFeedbackGeneration = 0
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false {
        didSet {
            if revealed != oldValue {
                if revealed { selectFirstShelfItems(presentation.shelves) }
                else {
                    cancelSelection(); texts.cancelSelection(); links.cancelSelection()
                    endAllShelfSearches()
                }
            }
        }
    }

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    var shelfHitGeometryUpdateCount = 0

    @Published private(set) var scrollOffset: CGFloat = 0
    @Published private(set) var favoritesOnly = false { didSet { filteredItems = nil; cachedSelectedItems = nil } }
    @Published private(set) var selectedIDs = Set<UUID>() { didSet { cachedSelectedItems = nil } }
    @Published private(set) var focusedID: UUID?
    @Published private(set) var selecting = false
    @Published var notice: String?
    @Published private(set) var size: Layout.Size = .medium
    @Published private(set) var theme: ShelfTheme = .soft
    func setTheme(_ value: ShelfTheme) { theme = value; defaults.set(value.rawValue, forKey: "shelfTheme") }
    func setSize(_ value: Layout.Size) {
        size = value; Layout.size = value
        defaults.set(value.rawValue, forKey: "lineSize")
        reloadThumbnails()
        setScrollOffset(scrollOffset)
        texts.scroll(0, width: viewportWidth)
        links.scroll(0, width: viewportWidth)
    }
    @Published private(set) var presentation: ShelfPresentation = .images
    @Published private(set) var activeShelf: Shelf = .images
    @Published private(set) var searchEditingShelf: Shelf?
    @Published private(set) var searchFocusRequests: [Shelf: Int] = [:]
    @Published private(set) var shelfSearchQuery = ""
    @Published private(set) var isShelfSearchActive = false
    private var imageSearchMatchingIDs: Set<UUID>? { didSet { filteredItems = nil; cachedSelectedItems = nil } }
    private var filteredItems: [Pegged]?
    private var cachedSelectedItems: [Pegged]?
    private var pendingSearchSelection = false
    var showingTexts: Bool {
        get { activeShelf == .texts }
        set { setPresentation(newValue ? .texts : .images, requestFocus: false) }
    }
    var panelHeight: CGFloat { Layout.panelHeight * CGFloat(presentation.shelves.count) }
    var activeSelectionCount: Int { switch activeShelf { case .texts: texts.selectedEntries.count; case .links: links.selectedEntries.count; case .images: selectedItems.count } }
    var activeFavoritesOnly: Bool { switch activeShelf { case .texts: texts.favoritesOnly; case .links: links.favoritesOnly; case .images: favoritesOnly } }
    var activeIDs: Set<UUID> { switch activeShelf { case .texts: texts.selectedIDs; case .links: links.selectedIDs; case .images: selectedIDs } }
    func setPresentation(_ value: ShelfPresentation, requestFocus: Bool = true) {
        let editing = searchEditingShelf
        let previousShelves = Set(presentation.shelves)
        let previousActiveShelf = activeShelf
        presentation = value
        if !value.shelves.contains(activeShelf) { activeShelf = value.shelves[0] }
        synchronizeShelfSearchScope()
        if let editing, !value.shelves.contains(editing) {
            searchEditingShelf = activeShelf
            searchFocusRequests[activeShelf, default: 0] += 1
        }
        if revealed && !isShelfSearchActive {
            for shelf in value.shelves where !previousShelves.contains(shelf) { resetShelfStart(shelf) }
            // Showing another row must not create another selection. Keep the
            // current row/column until it is hidden or has no selectable focus.
            if !value.shelves.contains(previousActiveShelf) || focusedItemID(for: activeShelf) == nil {
                selectFirstShelfItems(value.shelves)
            } else {
                if activeShelf != .images { cancelSelection() }
                if activeShelf != .texts { texts.cancelSelection() }
                if activeShelf != .links { links.cancelSelection() }
            }
        }
        defaults.set(value.rawValue, forKey: "shelfPresentation")
        if requestFocus { onFocusRequested?() }
    }
    func focusShelf(_ value: Shelf, requestFocus: Bool = true) {
        if (requestFocus || searchEditingShelf != value), searchEditingShelf != nil { searchEditingShelf = nil }
        if activeShelf != value { activeShelf = value }
        if !presentation.shelves.contains(value) { setPresentation(value.presentation, requestFocus: false) }
        if requestFocus { onFocusRequested?() }
    }
    func switchShelf() {
        let choices: [Shelf] = presentation.shelves.count > 1 ? presentation.shelves : library == nil ? [.images, .texts] : Shelf.allCases
        let index = choices.firstIndex(of: activeShelf) ?? 0; focusShelf(choices[(index + 1) % choices.count])
    }
    func toggleBothShelves() { setPresentation(presentation.shelves.count > 1 ? activeShelf.presentation : library == nil ? .both : .all) }
    func setShelfVisible(_ shelf: Shelf, visible: Bool) {
        var values = Set(presentation.shelves); if visible { values.insert(shelf) } else { values.remove(shelf) }
        if let value = ShelfPresentation.containing(values) { setPresentation(value, requestFocus: false) }
    }
    /// The final visible shelf closes the line; its layout remains available
    /// for the next deliberate reveal, just like closing with Escape.
    @discardableResult func toggleShelf(_ shelf: Shelf) -> Bool {
        let visible = presentation.shelves.contains(shelf)
        guard !visible || presentation.shelves.count > 1 else { return false }
        setShelfVisible(shelf, visible: !visible)
        onFocusRequested?(); return true
    }
    func undoShelfRemoval() {
        guard let library else { return }
        do { _ = try library.undoShelfRemoval() } catch { notice = error.localizedDescription }
    }
    func refreshShelfSearchAfterUndo(_ kinds: Set<LibraryKind>) {
        guard isShelfSearchActive, let shelfSearch else { return }
        for kind in kinds { shelfSearch.refreshAfterUndo(kind) }
        applyShelfSearchStates(shelfSearch.states)
    }
    func selectAllActive() { switch activeShelf { case .texts: texts.selectAll(); case .links: links.selectAll(); case .images: selectAll() } }
    private func selectableIDs(for shelf: Shelf) -> [UUID] {
        switch shelf {
        case .images: displayItems.filter { !$0.falling }.map(\.id)
        case .texts: texts.displayEntries.map(\.id)
        case .links: links.displayEntries.map(\.id)
        }
    }
    private func focusedItemID(for shelf: Shelf) -> UUID? {
        switch shelf { case .images: focusedID; case .texts: texts.focusedID; case .links: links.focusedID }
    }
    private func selectItem(_ id: UUID, on shelf: Shelf) {
        switch shelf {
        case .images: select(id)
        case .texts: texts.select(id, width: viewportWidth)
        case .links: links.select(id, width: viewportWidth)
        }
    }
    private func resetShelfStart(_ shelf: Shelf) {
        quickPages.removeValue(forKey: shelf)
        switch shelf {
        case .images: cancelSelection(); setScrollOffset(0)
        case .texts: texts.cancelSelection(); texts.scroll(texts.scrollOffset, width: viewportWidth)
        case .links: links.cancelSelection(); links.scroll(links.scrollOffset, width: viewportWidth)
        }
    }
    /// A fresh reveal starts the rows at the beginning with one selection:
    /// images first, or the first nonempty visible row when images are absent.
    /// Do not request keyboard focus: automatic capture peeks share this path.
    func selectFirstShelfItems(_ shelves: [Shelf]) {
        guard revealed else { return }
        cancelSelection(); texts.cancelSelection(); links.cancelSelection()
        let visible = presentation.shelves.filter(shelves.contains)
        for shelf in visible { resetShelfStart(shelf) }
        let preferred = visible.contains(.images) ? [.images] + visible.filter { $0 != .images } : visible
        guard let shelf = preferred.first(where: { firstSelectableID(for: $0) != nil }) else {
            if let shelf = visible.first { focusShelf(shelf, requestFocus: false) }
            return
        }
        focusShelf(shelf, requestFocus: false)
        if let id = firstSelectableID(for: shelf) { selectItem(id, on: shelf) }
    }
    /// Opening only needs a head item, not a copied ID array for every row.
    private func firstSelectableID(for shelf: Shelf) -> UUID? {
        switch shelf {
        case .images: displayItems.first(where: { !$0.falling })?.id
        case .texts: texts.displayEntries.first?.id
        case .links: links.displayEntries.first?.id
        }
    }
    /// The naming queue owns its own immutable IDs. Only move the visual focus;
    /// never replace the selection as Enter advances through that queue.
    func focusNameAndPinTarget(_ id: UUID, on shelf: Shelf) {
        switch shelf {
        case .images: select(id, preservingSelection: true)
        case .texts: texts.select(id, preservingSelection: true, width: viewportWidth)
        case .links: links.select(id, preservingSelection: true, width: viewportWidth)
        }
    }
    func moveToShelfBoundary(last: Bool) {
        quickPages.removeValue(forKey: activeShelf)
        let values = selectableIDs(for: activeShelf)
        guard let id = last ? values.last : values.first else { return }
        selectItem(id, on: activeShelf)
    }
    private struct QuickPage {
        let start: Int
        let anchor: UUID
        let offset: CGFloat
        let width: CGFloat
        let spacing: CGFloat
        let count: Int
        let first: UUID?
        let last: UUID?
        let query: String
        let favorites: Bool
    }
    @Published private var quickPages = [Shelf: QuickPage]()
    private var quickPageCapacity: Int {
        min(9, max(1, Int(floor((viewportWidth - Layout.x(index: 0)) / Layout.spacing)) + 1))
    }
    /// Nil cards retain a falling image's visual column until it disappears.
    private struct QuickSelectionData {
        let count: Int
        let offset: CGFloat
        let idAt: (Int) -> UUID?
        var first: UUID? { count > 0 ? idAt(0) : nil }
        var last: UUID? { count > 0 ? idAt(count - 1) : nil }
        func contains(_ index: Int) -> Bool { index >= 0 && index < count }
        func page(_ start: Int, capacity: Int) -> [UUID] {
            (start..<min(count, start + capacity)).compactMap(idAt)
        }
    }
    /// Only the numbered viewport needs IDs. Mapping the entire month on
    /// every scroll/hover makes an otherwise virtualized row scale with history.
    private func quickSelectionData() -> QuickSelectionData {
        switch activeShelf {
        case .images:
            let values = displayItems
            return QuickSelectionData(count: values.count, offset: scrollOffset) { values[$0].falling ? nil : values[$0].id }
        case .texts:
            let values = texts.displayEntries
            return QuickSelectionData(count: values.count, offset: texts.scrollOffset) { values[$0].id }
        case .links:
            let values = links.displayEntries
            return QuickSelectionData(count: values.count, offset: links.scrollOffset) { values[$0].id }
        }
    }
    private func quickPageStart(_ data: QuickSelectionData) -> Int? {
        guard let page = quickPages[activeShelf], page.offset == data.offset,
              page.width == viewportWidth, page.spacing == Layout.spacing,
              page.count == data.count, page.first == data.first,
              page.last == data.last, page.query == shelfSearchQuery,
              page.favorites == activeFavoritesOnly,
              data.contains(page.start) else { return nil }
        let start = page.start
        let ids = data.page(start, capacity: quickPageCapacity)
        guard ids.contains(page.anchor) else { return nil }
        if let focus = focusedItemID(for: activeShelf), !ids.contains(focus) { return nil }
        return start
    }
    var quickSelectionIDs: [UUID] {
        guard searchEditingShelf == nil else { return [] }
        let data = quickSelectionData()
        if let start = quickPageStart(data) {
            return data.page(start, capacity: quickPageCapacity)
        }
        return visibleQuickSelectionIDs(count: data.count, offset: data.offset, idAt: data.idAt)
    }
    /// Move the numbered group, including when the final group is narrower
    /// than the viewport. Keep an explicit anchor so clamping the scroll at the
    /// end does not renumber backfilled cards from the preceding page.
    @discardableResult func moveShelfPage(_ delta: Int, allowedIDs: Set<UUID>? = nil) -> UUID? {
        guard delta != 0, searchEditingShelf == nil else { return nil }
        let data = quickSelectionData(), visible = quickSelectionIDs
        guard data.count > 0 else { return nil }
        let start = quickPageStart(data) ?? firstVisibleQuickColumn(offset: data.offset)
        let capacity = quickPageCapacity, step = delta < 0 ? -capacity : capacity
        let slot = focusedItemID(for: activeShelf).flatMap { visible.firstIndex(of: $0) } ?? 0
        var destination = delta < 0 ? max(0, start + step) : start + step
        guard destination != start else { return nil }
        while data.contains(destination) {
            let page = data.page(destination, capacity: capacity)
            let candidates = page.filter { allowedIDs?.contains($0) ?? true }
            if let anchor = page.first, !candidates.isEmpty {
                let target = candidates[min(slot, candidates.count - 1)]
                let offset = CGFloat(destination) * Layout.spacing
                switch activeShelf {
                case .images: setScrollOffset(offset)
                case .texts: texts.scroll(texts.scrollOffset - offset, width: viewportWidth)
                case .links: links.scroll(links.scrollOffset - offset, width: viewportWidth)
                }
                selectItem(target, on: activeShelf)
                let actual = quickSelectionData()
                quickPages[activeShelf] = QuickPage(start: destination, anchor: anchor, offset: actual.offset, width: viewportWidth,
                    spacing: Layout.spacing, count: actual.count, first: actual.first,
                    last: actual.last, query: shelfSearchQuery, favorites: activeFavoritesOnly)
                return target
            }
            if delta < 0, destination == 0 { break }
            destination = delta < 0 ? max(0, destination + step) : destination + step
        }
        return nil
    }
    private func firstVisibleQuickColumn(offset: CGFloat) -> Int {
        max(0, Int(ceil((offset - Layout.edgePadding - Layout.cardWidth / 2) / Layout.spacing)))
    }
    private func visibleQuickSelectionIDs(count: Int, offset: CGFloat, idAt: (Int) -> UUID?) -> [UUID] {
        let first = firstVisibleQuickColumn(offset: offset)
        guard first < count else { return [] }
        let end = min(count, first + Int(ceil(viewportWidth / Layout.spacing)) + 2)
        var result = [UUID](); result.reserveCapacity(9)
        for index in first..<end {
            guard Layout.x(index: index, scrollOffset: offset) <= viewportWidth else { break }
            if let id = idAt(index) { result.append(id) }
            if result.count == 9 { break }
        }
        return result
    }
    func quickSelectionNumber(_ id: UUID, shelf: Shelf) -> Int? {
        guard activeShelf == shelf else { return nil }
        return quickSelectionIDs.firstIndex(of: id).map { $0 + 1 }
    }
    func selectQuickSlot(_ slot: Int) {
        let ids = quickSelectionIDs
        guard ids.indices.contains(slot) else { return }
        selectItem(ids[slot], on: activeShelf)
    }
    var activeActionIDs: [UUID] {
        let selected = activeIDs
        let ordered = selectableIDs(for: activeShelf)
        if !selected.isEmpty { return ordered.filter { selected.contains($0) } }
        return focusedItemID(for: activeShelf).map { [$0] } ?? []
    }
    func removeActiveSelectionFromShelf() {
        let shelf = activeShelf
        let ids: [UUID]
        switch shelf {
        case .images: ids = selectedItems.map(\.id)
        case .texts: ids = texts.displayEntries.filter { texts.selectedIDs.contains($0.id) }.map(\.id)
        case .links: ids = links.displayEntries.filter { links.selectedIDs.contains($0.id) }.map(\.id)
        }
        removeFromShelf(ids, on: shelf)
    }
    /// The action bar captures IDs before its editor takes focus. Preserve its
    /// target and the same surviving-neighbor behavior as the native S action.
    func removeFromShelf(_ capturedIDs: [UUID], on shelf: Shelf, focusedID: UUID? = nil) {
        let ordered = selectableIDs(for: shelf), captured = Set(capturedIDs)
        let ids = ordered.filter(captured.contains)
        guard !ids.isEmpty else { return }
        let selected = Set(ids)
        let anchor = (focusedID ?? focusedItemID(for: shelf)).flatMap { selected.contains($0) ? ordered.firstIndex(of: $0) : nil }
            ?? ordered.firstIndex(where: selected.contains) ?? 0
        if let library {
            do { try library.removeFromShelf(ids) } catch { notice = error.localizedDescription; return }
        } else {
            switch shelf {
            case .images: for id in ids { discard(id) }
            case .texts: for id in ids { texts.removeFromShelf(id) }
            case .links: for id in ids { links.removeFromShelf(id) }
            }
        }
        let remaining = Set(selectableIDs(for: shelf))
        guard !selected.isSubset(of: remaining) else { return }
        // Continue to the right of the removed focus; at the end, use the
        // nearest surviving item on the left. Only the current filtered row
        // contributes candidates, even after a batch removal.
        let candidates = Array(ordered.dropFirst(anchor + 1)) + ordered.prefix(anchor + 1).reversed()
        switch shelf { case .images: cancelSelection(); case .texts: texts.cancelSelection(); case .links: links.cancelSelection() }
        if let next = candidates.first(where: remaining.contains) { selectItem(next, on: shelf) }
    }
    func setActiveFavorites(_ value: Bool) {
        switch activeShelf { case .texts: texts.setFavoritesOnly(value); case .links: links.setFavoritesOnly(value); case .images: setFavoritesOnly(value) }
        shelfSearch?.setFavoritesOnly(value, for: activeShelf.libraryKind)
    }

    var shelfSearchResultCount: Int {
        presentation.shelves.reduce(0) { $0 + searchResultCount(for: $1) }
    }
    var shelfSearchIsSearching: Bool {
        presentation.shelves.contains { shelfSearch?.isSearching(for: $0.libraryKind) == true }
    }
    var shelfSearchError: String? {
        presentation.shelves.compactMap { shelfSearch?.error(for: $0.libraryKind) }.first
    }
    private func searchResultCount(for shelf: Shelf) -> Int {
        switch shelf { case .images: displayItems.count; case .texts: texts.displayEntries.count; case .links: links.displayEntries.count }
    }
    /// Search and ordinary browsing share vertical row navigation. A native
    /// search editor keeps its arrows; empty and hidden rows are skipped.
    @discardableResult func moveSearchResultShelf(_ delta: Int) -> Bool {
        guard isShelfSearchActive else { return false }
        return moveSelectionShelf(delta)
    }
    @discardableResult func moveSelectionShelf(_ delta: Int) -> Bool {
        guard searchEditingShelf == nil, delta != 0,
              let currentRow = presentation.shelves.firstIndex(of: activeShelf) else { return false }
        let column = focusedItemID(for: activeShelf).flatMap { selectableIDs(for: activeShelf).firstIndex(of: $0) } ?? 0
        let step = delta < 0 ? -1 : 1
        var row = currentRow + step
        while presentation.shelves.indices.contains(row) {
            let shelf = presentation.shelves[row], results = selectableIDs(for: shelf)
            if !results.isEmpty {
                let target = results[min(column, results.count - 1)]
                cancelSelection(); texts.cancelSelection(); links.cancelSelection()
                focusShelf(shelf, requestFocus: false)
                selectItem(target, on: shelf)
                return true
            }
            row += step
        }
        return false
    }
    func beginShelfSearch(_ shelf: Shelf? = nil) {
        guard shelfSearch != nil else { return }
        // The anchor owns native focus only. Opening search never reveals a
        // row that the user turned off, and never changes the common phrase.
        let target = shelf.flatMap { presentation.shelves.contains($0) ? $0 : nil } ?? activeShelf
        focusShelf(target)
        pendingSearchSelection = false
        isShelfSearchActive = true
        synchronizeShelfSearchScope()
        searchEditingShelf = target
        searchFocusRequests[target, default: 0] += 1
    }
    func updateShelfSearch(_ query: String, for _: Shelf) {
        guard shelfSearch != nil, shelfSearchQuery != query || !isShelfSearchActive else { return }
        pendingSearchSelection = false
        for shelf in Shelf.allCases { clearSearchSelection(shelf) }
        shelfSearchQuery = query
        isShelfSearchActive = true
        synchronizeShelfSearchScope()
    }
    private func clearSearchSelection(_ shelf: Shelf) {
        switch shelf {
        case .images: cancelSelection(); setScrollOffset(0)
        case .texts: texts.cancelSelection(); texts.scrollOffset = 0
        case .links: links.cancelSelection(); links.scroll(links.scrollOffset, width: viewportWidth)
        }
    }
    private func synchronizeShelfSearchScope() {
        guard let shelfSearch, isShelfSearchActive else { return }
        for shelf in Shelf.allCases {
            if presentation.shelves.contains(shelf) {
                shelfSearch.setFavoritesOnly(favoritesOnly(for: shelf), for: shelf.libraryKind)
                shelfSearch.setActive(true, for: shelf.libraryKind)
                shelfSearch.update(shelfSearchQuery, for: shelf.libraryKind)
            } else if shelfSearch.isActive(for: shelf.libraryKind) {
                shelfSearch.close(shelf.libraryKind)
            }
        }
        applyShelfSearchStates(shelfSearch.states)
    }
    func shelfSearchBeganEditing(_ shelf: Shelf) {
        guard isShelfSearchActive, presentation.shelves.contains(shelf) else { return }
        focusShelf(shelf, requestFocus: false); searchEditingShelf = shelf
    }
    func finishShelfSearchEditing(_ shelf: Shelf, selectFirst: Bool = true) {
        if searchEditingShelf == shelf { searchEditingShelf = nil }
        if selectFirst { pendingSearchSelection = true; applyShelfSearchStates(shelfSearch?.states ?? [:]) }
    }
    @discardableResult func closeShelfSearch(_ _: Shelf? = nil, requestFocus: Bool = true) -> Bool {
        guard isShelfSearchActive else { return false }
        endAllShelfSearches()
        if requestFocus { onFocusRequested?() }
        return true
    }
    private func endAllShelfSearches() {
        guard isShelfSearchActive || searchEditingShelf != nil else { return }
        searchEditingShelf = nil; pendingSearchSelection = false
        isShelfSearchActive = false; shelfSearchQuery = ""; shelfSearch?.close()
        applyShelfSearchStates([:])
    }
    private func favoritesOnly(for shelf: Shelf) -> Bool {
        switch shelf { case .images: favoritesOnly; case .texts: texts.favoritesOnly; case .links: links.favoritesOnly }
    }
    private func applyShelfSearchStates(_ states: [LibraryKind: ShelfSearchState]) {
        objectWillChange.send()
        let imageIDs = states[.image]?.matchingIDs
        if imageSearchMatchingIDs != imageIDs {
            imageSearchMatchingIDs = imageIDs
            sanitizeSelection(); setScrollOffset(scrollOffset)
        }
        texts.setSearchMatchingIDs(states[.text]?.matchingIDs, width: viewportWidth)
        links.setSearchMatchingIDs(states[.link]?.matchingIDs, width: viewportWidth)
        if pendingSearchSelection, !shelfSearchIsSearching {
            pendingSearchSelection = false
            let choices = [activeShelf] + presentation.shelves.filter { $0 != activeShelf }
            if let shelf = choices.first(where: { searchResultCount(for: $0) > 0 }) {
                focusShelf(shelf, requestFocus: false)
                switch shelf {
                case .images: if focusedID == nil { moveSelection(1) }
                case .texts: if texts.focusedID == nil { texts.moveSelection(1, width: viewportWidth) }
                case .links: if links.focusedID == nil { links.moveSelection(1, width: viewportWidth) }
                }
            }
        }
    }

    func pinActiveSelection() {
        switch activeShelf {
        case .texts: for id in texts.selectedIDs.isEmpty ? Set(texts.focusedID.map { [$0] } ?? []) : texts.selectedIDs { texts.togglePin(id) }
        case .links: for id in links.selectedIDs.isEmpty ? Set(links.focusedID.map { [$0] } ?? []) : links.selectedIDs { links.togglePin(id) }
        case .images: for id in selectedIDs.isEmpty ? Set(focusedID.map { [$0] } ?? []) : selectedIDs { pinFromUI(id) }
        }
    }
    var focusedActionID: UUID? {
        switch activeShelf {
        case .images: focusedID ?? selectedItems.first?.id
        case .texts: texts.focusedID ?? texts.selectedEntries.first?.id
        case .links: links.focusedID ?? links.selectedEntries.first?.id
        }
    }
    let texts: TextHistory
    let links: LinkHistory
    let library: LibraryStore?
    let shelfSearch: ShelfSearchModel?
    let keyboardBindings: KeyboardBindings
    private var librarySubscription: AnyCancellable?
    private var shelfSearchSubscription: AnyCancellable?
    private var shelfSearchFilterSubscriptions = Set<AnyCancellable>()
    var onLibraryRequested: (() -> Void)?
    var onPasteRequested: (([UUID]) -> Void)?
    var onTagRequested: (([UUID]) -> Void)?
    var onImageMarkupRequested: ((UUID) -> Void)?
    var onFlushPreview: () -> Bool = { true }
    var onImageTextCopyRequested: ((UUID) -> Void)?
    var onCommandsRequested: (() -> Void)?
    var onPinToFolderRequested: (([UUID]) -> Void)?
    var onNameAndPinRequested: ((UUID) -> Void)?
    var onNameAndPinBatchRequested: (([UUID]) -> Void)?
    var onTextPreviewRequested: ((UUID) -> Void)?
    var onTextTrashRequested: ((UUID) -> Void)?
    var onLinkPreviewRequested: ((UUID) -> Void)?
    var onLinkItemsVisible: (([UUID]) -> Void)?
    var onSettingsRequested: (() -> Void)?
    var onFocusRequested: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onTrashRequested: (() -> Void)?
    var onImageTrashRequested: ((TrashSelection) -> Void)?
    private var selectionAnchor: UUID?
    private(set) var viewportWidth: CGFloat = 1024
    private let history: ImageHistory
    var historyFiles: HistoryFiles { history.files }
    private let defaults: UserDefaults
    let thumbnails = ThumbnailStore()
    private var arrivalIDs = Set<UUID>()
    private var lastThumbnailIDs = Set<UUID>()
    private var lastThumbnailPixels = 0
    private let copyImageOverride: ((URL) -> Void)?

    var retentionDays: Int { history.retentionDays }
    func retentionDays(for kind: LibraryKind) -> Int { HistoryRetention.days(kind, defaults: defaults) }
    var displayItems: [Pegged] {
        if !favoritesOnly && imageSearchMatchingIDs == nil { return items }
        if let filteredItems { return filteredItems }
        let values = items.filter { (!favoritesOnly || $0.pinned) && (imageSearchMatchingIDs?.contains($0.id) ?? true) }
        filteredItems = values
        return values
    }
    var selectedItems: [Pegged] {
        if selectedIDs.isEmpty { return [] }
        if let cachedSelectedItems { return cachedSelectedItems }
        let values = displayItems.filter { selectedIDs.contains($0.id) && !$0.falling }
        cachedSelectedItems = values
        return values
    }
    var selectedAppCopyCount: Int { selectedItems.filter { history.files.isAppCopy($0.url) }.count }

    func isAppCopy(_ id: UUID) -> Bool {
        items.first(where: { $0.id == id }).map { history.files.isAppCopy($0.url) } ?? false
    }

    func setFavoritesOnly(_ on: Bool) {
        favoritesOnly = on
        cancelSelection()
        setScrollOffset(0)
    }

    func startSelection() { selecting = true; onFocusRequested?() }
    func cancelSelection() {
        if selecting { selecting = false }
        if !selectedIDs.isEmpty { selectedIDs.removeAll() }
        if focusedID != nil { focusedID = nil }
        selectionAnchor = nil
    }

    func select(_ id: UUID, toggle: Bool = false, extending: Bool = false, preservingSelection: Bool = false) {
        let visible = displayItems
        guard let target = visible.firstIndex(where: { $0.id == id && !$0.falling }) else { return }
        if extending, let anchor = selectionAnchor,
           let start = visible.firstIndex(where: { $0.id == anchor && !$0.falling }) {
            selectedIDs = Set(visible[min(start, target)...max(start, target)].filter { !$0.falling }.map(\.id))
        } else if toggle {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
            selectionAnchor = id
        } else if !preservingSelection || !selectedIDs.contains(id) {
            selectedIDs = [id]
            selectionAnchor = id
        }
        focusedID = id
        if extending || toggle { selecting = true }
        keepVisible(index: target)
    }

    func selectAll() {
        selecting = true
        selectedIDs = Set(displayItems.filter { !$0.falling }.map(\.id))
        focusedID = displayItems.first(where: { !$0.falling })?.id
        selectionAnchor = focusedID
    }

    func moveSelection(_ delta: Int, extending: Bool = false) {
        let live = displayItems.filter { !$0.falling }
        guard !live.isEmpty else { return }
        let current = focusedID.flatMap { id in live.firstIndex(where: { $0.id == id }) }
        let target = current.map { max(0, min(live.count - 1, $0 + delta)) } ?? 0
        select(live[target].id, extending: extending)
    }

    func actionItems(for id: UUID) -> [Pegged] {
        selectedIDs.contains(id) && selectedItems.count > 1 ? selectedItems : items.filter { $0.id == id && !$0.falling }
    }
    @discardableResult func copySelection() -> Bool {
        guard onFlushPreview() else { return false }
        switch activeShelf { case .texts: return texts.copySelection(); case .links: return links.copySelection(); case .images: return copyItems(selectedItems) }
    }
    func copyAction(_ id: UUID) { copyItems(actionItems(for: id)) }
    func dragItems(_ id: UUID) -> [ShelfDragItem] {
        guard onFlushPreview() else { return [] }
        let images = actionItems(for: id)
        guard !images.isEmpty else { return [] }
        return images.map { image in
            ShelfDragItem(id: image.id, sourceURL: image.url, writer: image.url as NSURL, image: image.thumb ?? makeThumbnail(image.url))
        }
    }
    func discardAction(_ id: UUID) {
        if actionItems(for: id).count > 1 { focusShelf(.images); onTrashRequested?() }
        else { discard(id) }
    }

    private func keepVisible(index: Int) {
        let x = Layout.x(index: index)
        if x - Layout.cardWidth / 2 < scrollOffset {
            setScrollOffset(x - Layout.cardWidth / 2 - Layout.edgePadding)
        } else if x + Layout.cardWidth / 2 > scrollOffset + viewportWidth {
            setScrollOffset(x + Layout.cardWidth / 2 + Layout.edgePadding - viewportWidth)
        }
    }

    @discardableResult
    func togglePin(_ id: UUID) throws -> Bool {
        guard onFlushPreview() else { throw HistoryFiles.Failure.unsafeFile }
        guard let index = items.firstIndex(where: { $0.id == id }),
              let entry = try history.togglePin(items[index].url, id: id) else { return false }
        items[index].url = entry.url
        items[index].pinned = entry.pinned
        items[index].originalPath = entry.originalPath
        items[index].managedCopy = history.files.isAppCopy(entry.url)
        sanitizeSelection()
        setScrollOffset(scrollOffset)
        return entry.pinned
    }

    func pinFromUI(_ id: UUID) {
        do { try togglePin(id) }
        catch { notice = L("Could not save a favorite copy") }
    }

    func exportSelected(to folder: URL?) throws -> HistoryFiles.ExportResult? {
        guard let folder else { return nil }
        guard onFlushPreview() else { throw HistoryFiles.Failure.unsafeFile }
        let sources = selectedItems.map { item in
            (url: item.url, name: HistoryFiles.exportName(for: item.url, originalPath: item.originalPath))
        }
        return try history.files.export(sources, to: folder)
    }

    struct TrashSelection {
        let images: [Pegged]
        let appCopies: Int
        var originals: Int { images.count - appCopies }
    }

    func trashSelectionSnapshot() -> TrashSelection {
        TrashSelection(images: selectedItems, appCopies: selectedAppCopyCount)
    }

    /// The modal confirmation supplies an immutable snapshot. A changed
    /// selection/path cannot silently broaden the files to be processed.
    @discardableResult
    func trashSelection(_ snapshot: TrashSelection, confirmed: Bool) -> Int {
        guard confirmed, onFlushPreview() else { return 0 }
        if let library {
            let currentIDs = snapshot.images.filter { image in items.contains { $0.id == image.id && $0.url == image.url && !$0.falling } }.map(\.id)
            do { try library.trash(currentIDs); return currentIDs.count } catch { notice = error.localizedDescription; return 0 }
        }
        var removed = 0
        for image in snapshot.images {
            guard let current = items.first(where: { $0.id == image.id && $0.url == image.url && !$0.falling }) else { continue }
            if history.files.isAppCopy(current.url) {
                do { try history.files.trashAppCopy(current.url) }
                catch { notice = L("Some app copies could not be moved to Trash"); continue }
            }
            history.remove(current.url)
            items.removeAll { $0.id == current.id }
            hitRects[current.id] = nil
            removed += 1
        }
        sanitizeSelection()
        setScrollOffset(scrollOffset)
        return removed
    }

    private func sanitizeSelection() {
        let visibleIDs = Set(displayItems.filter { !$0.falling }.map(\.id))
        selectedIDs.formIntersection(visibleIDs)
        if let id = focusedID, !visibleIDs.contains(id) { focusedID = nil }
        if let anchor = selectionAnchor, !visibleIDs.contains(anchor) { selectionAnchor = nil }
    }
    var maximumScrollOffset: CGFloat { Layout.maximumOffset(count: displayItems.count, width: viewportWidth) }
    var visibleRange: Range<Int> { Layout.visibleRange(count: displayItems.count, width: viewportWidth, offset: scrollOffset) }

    /// Top-origin panel coordinates. All configured rows, including mixed
    /// two-row layouts, accept a swipe in their gaps when that row overflows.
    /// Looking only at the image row made text/link gaps pass through instead.
    func scrollableShelfBandContains(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.x < viewportWidth, point.y >= 0,
              point.y < panelHeight else { return false }
        let index = Int(point.y / Layout.panelHeight)
        guard presentation.shelves.indices.contains(index) else { return false }
        let rowTop = CGFloat(index) * Layout.panelHeight
        guard point.y >= rowTop + Layout.ropeTop,
              point.y < rowTop + Layout.panelHeight - 20 else { return false }
        let count: Int
        switch presentation.shelves[index] {
        case .images: count = displayItems.count
        case .texts: count = texts.displayEntries.count
        case .links: count = links.displayEntries.count
        }
        return Layout.maximumOffset(count: count, width: viewportWidth) > 0
    }

    func setViewportWidth(_ width: CGFloat) {
        viewportWidth = width.isFinite ? max(1, width) : 1
        texts.scroll(0, width: viewportWidth)
        links.scroll(0, width: viewportWidth)
        setScrollOffset(scrollOffset)
    }
    func fitShelves(in height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let limit = height / CGFloat(presentation.shelves.count)
        if Layout.maximumRowHeight != limit { Layout.maximumRowHeight = limit; objectWillChange.send(); setScrollOffset(scrollOffset) }
    }

    func setScrollOffset(_ offset: CGFloat) {
        guard offset.isFinite else { return }
        let clamped = max(0, min(maximumScrollOffset, offset))
        if scrollOffset != clamped { scrollOffset = clamped }
        refreshThumbnails()
    }

    func scroll(horizontal: CGFloat, vertical: CGFloat, precise: Bool) {
        let delta = abs(horizontal) > abs(vertical) ? horizontal : vertical
        setScrollOffset(scrollOffset - delta * (precise ? 1 : 24))
    }

    func setRetentionDays(_ days: Int) {
        history.setRetentionDays(days)
        texts.prune()
        syncHistory()
    }
    func setRetentionDays(_ days: Int, for kind: LibraryKind) {
        guard ImageHistory.dayChoices.contains(days) else { return }
        if kind == .image {
            for other in [LibraryKind.text, .link] where defaults.object(forKey: HistoryRetention.key(other)) == nil {
                defaults.set(retentionDays(for: other), forKey: HistoryRetention.key(other))
            }
            setRetentionDays(days); return
        }
        objectWillChange.send(); defaults.set(days, forKey: HistoryRetention.key(kind))
        if let library { do { try library.prune() } catch { notice = error.localizedDescription } }
        else { texts.prune() }
    }


    var newestID: UUID? { items.first(where: { !$0.falling })?.id }

    var globalSearchShortcut: KeyShortcut? {
        if defaults.bool(forKey: "globalSearchShortcutOff") { return nil }
        guard let data = defaults.data(forKey: "globalSearchShortcut") else {
            return KeyShortcut(keyCode: 1, modifiers: controlKey | optionKey, keyLabel: "S")
        }
        guard let value = try? JSONDecoder().decode(KeyShortcut.self, from: data), value.isValid else { return nil }
        return value
    }
    func saveGlobalSearchShortcut(_ value: KeyShortcut?) {
        guard value == nil || value?.isValid == true else { return }
        defaults.set(value == nil, forKey: "globalSearchShortcutOff")
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "globalSearchShortcut") }
        else { defaults.removeObject(forKey: "globalSearchShortcut") }
    }

    var copyLatestShortcut: KeyShortcut? {
        guard let data = defaults.data(forKey: "copyLatestShortcut"),
              let value = try? JSONDecoder().decode(KeyShortcut.self, from: data), value.isValid else { return nil }
        return value
    }

    func saveCopyLatestShortcut(_ value: KeyShortcut?) {
        if let value, value.isValid, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: "copyLatestShortcut")
        } else if value == nil { defaults.removeObject(forKey: "copyLatestShortcut") }
    }
    var libraryShortcut: KeyShortcut? {
        guard let data = defaults.data(forKey: "libraryShortcut"), let value = try? JSONDecoder().decode(KeyShortcut.self, from: data), value.isValid else { return nil }; return value
    }
    func saveLibraryShortcut(_ value: KeyShortcut?) {
        if let value, value.isValid, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "libraryShortcut") }
        else if value == nil { defaults.removeObject(forKey: "libraryShortcut") }
    }

    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    init(defaults: UserDefaults = .standard, inbox: URL = Inbox.folder,
         now: @escaping () -> Date = Date.init, breeze: Bool = true,
         moveToTrash: @escaping (URL) throws -> URL = HistoryFiles.systemTrash,
         copyImage: ((URL) -> Void)? = nil, copyText: ((String) -> Void)? = nil, library: LibraryStore? = nil, pruneOnLoad: Bool = true) {
        self.library = library
        shelfSearch = library.map { ShelfSearchModel(store: $0) }
        self.defaults = defaults
        keyboardBindings = KeyboardBindings(defaults: defaults)
        theme = ShelfTheme(rawValue: defaults.string(forKey: "shelfTheme") ?? "") ?? .soft
        let savedSize = Layout.Size(rawValue: defaults.string(forKey: "lineSize") ?? "") ?? .medium
        size = savedSize
        Layout.size = savedSize
        Layout.maximumRowHeight = .greatestFiniteMagnitude
        let savedPresentation = ShelfPresentation(rawValue: defaults.string(forKey: "shelfPresentation") ?? "") ?? .images
        presentation = savedPresentation
        activeShelf = savedPresentation.shelves[0]
        copyImageOverride = copyImage
        texts = TextHistory(defaults: defaults, folder: inbox.appendingPathComponent("Texts"), now: now, moveToTrash: moveToTrash, copyText: copyText, library: library, pruneOnLoad: pruneOnLoad)
        links = LinkHistory(store: library, copy: copyText)
        history = ImageHistory(defaults: defaults, inbox: inbox, now: now, moveToTrash: moveToTrash, pruneOnLoad: pruneOnLoad, library: library)
        items = history.entries.map { Pegged(id: $0.id, url: $0.url, thumb: nil, pinned: $0.pinned, managedCopy: history.files.isAppCopy($0.url), originalPath: $0.originalPath, title: $0.title) }
        thumbnails.onLoad = { [weak self] in self?.refreshThumbnails(force: true) }
        refreshThumbnails()
        if let library { librarySubscription = library.$revision.dropFirst().sink { [weak self, weak library] _ in if library?.changedKinds.contains(.image) == true { self?.reloadFromLibrary() } } }
        shelfSearchSubscription = shelfSearch?.$states.receive(on: RunLoop.main).sink { [weak self] states in
            guard let self, self.shelfSearch?.states == states else { return }
            self.applyShelfSearchStates(states)
        }
        $favoritesOnly.dropFirst().sink { [weak shelfSearch] in shelfSearch?.setFavoritesOnly($0, for: .image) }.store(in: &shelfSearchFilterSubscriptions)
        texts.$favoritesOnly.dropFirst().sink { [weak shelfSearch] in shelfSearch?.setFavoritesOnly($0, for: .text) }.store(in: &shelfSearchFilterSubscriptions)
        links.$favoritesOnly.dropFirst().sink { [weak shelfSearch] in shelfSearch?.setFavoritesOnly($0, for: .link) }.store(in: &shelfSearchFilterSubscriptions)
        if breeze { scheduleGust() }
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        if let library {
            do {
                let record = try library.captureImage(url)
                thumbnails.seed(thumb, url: url, pixels: Int(320 * size.scale)); arrivalIDs.insert(record.id)
                if let index = items.firstIndex(where: { $0.id == record.id }) { items[index].thumb = thumb; items[index].flying = flying }
                setScrollOffset(0); if !quietly { play("Tink", volume: 0.35) }; return record.id
            } catch { notice = L("Library could not be saved or opened"); return nil }
        }
        var item = Pegged(url: url, thumb: thumb, managedCopy: history.files.isAppCopy(url))
        thumbnails.seed(thumb, url: url, pixels: Int(320 * size.scale))
        arrivalIDs.insert(item.id)
        item.flying = flying
        items.insert(item, at: 0)
        history.add(url)
        setScrollOffset(0)
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        if let library { onFall?(items[i]); do { try library.removeFromShelf([id]) } catch { notice = error.localizedDescription }; return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        history.remove(items[i].url)
        sanitizeSelection()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.items.removeAll { $0.id == id }
            self.setScrollOffset(self.scrollOffset)
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        // A month of cards must clear in one persisted update. Only cards
        // currently on screen need the fall animation.
        let displayed = displayItems
        for index in visibleRange where !displayed[index].falling && !displayed[index].pinned { onFall?(displayed[index]) }
        history.clear()
        items.removeAll { !$0.pinned }
        cancelSelection()
        hitRects.removeAll()
        scrollOffset = 0
        play("Pop", volume: 0.25)
    }

    /// Left/right mean the visible shelf order, including a favorites filter.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = displayItems.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    func takeDown(_ id: UUID, toTheLeft: Bool) {
        guard onFlushPreview() else { return }
        let images = neighbours(of: id, toTheLeft: toTheLeft)
        guard !images.isEmpty else { return }
        // The same snapshot/confirmation policy as other local batch actions.
        onImageTrashRequested?(TrashSelection(images: images,
            appCopies: images.filter { history.files.isAppCopy($0.url) }.count))
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        history.prune()
        texts.prune()
        syncHistory()
    }

    // MARK: Actions on one photo

    @discardableResult func copy(_ id: UUID) -> Bool {
        copyItems(items.filter { $0.id == id && !$0.falling })
    }

    @discardableResult func copyItems(_ images: [Pegged], to pasteboard: NSPasteboard? = nil) -> Bool {
        guard onFlushPreview() else { return false }
        let images = library == nil ? images : images.compactMap { snapshot in items.first { $0.id == snapshot.id && !$0.falling } }
        guard !images.isEmpty else { return false }
        if let copyImageOverride, pasteboard == nil { images.forEach { copyImageOverride($0.url) } }
        else {
            do {
                guard ClipboardTransfer.write(try ClipboardTransfer.imageItems(images.map(\.url)), to: pasteboard ?? .general) else {
                    notice = L("Could not copy selected items"); return false
                }
            } catch { notice = L("Could not copy selected items"); return false }
        }
        let id = images.first!.id
        copiedID = id
        try? library?.markCopied(images.map(\.id))
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copyFeedbackGeneration == generation { self?.copiedID = nil }
        }
        return true
    }

    func open(_ id: UUID) {
        guard onFlushPreview() else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard onFlushPreview() else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let library { do { try library.trash([id]) } catch { notice = error.localizedDescription }; return }
        if history.files.isAppCopy(item.url) {
            do { try history.files.trashAppCopy(item.url) }
            catch { notice = L("Some app copies could not be moved to Trash"); return }
        }
        drop(id, quietly: true)
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return history.files.isAppCopy(item.url)
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        guard onFlushPreview() else { return }
        if let library { do { try library.removeFromShelf([id]) } catch { notice = error.localizedDescription }; return }
        if isInInbox(id) { trash(id) } else { drop(id, quietly: quietly) }
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Tendedero's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    /// Moves along a line that holds more than fit, from a scroll gesture.
    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard onFlushPreview() else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press opens our editable image markup preview. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            if let library { Trim.shared.edit(id, store: library, size: item.thumb?.size ?? CGSize(width: 720, height: 450)) }
        } else {
            onImageMarkupRequested?(id)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        thumbnails.invalidate(); lastThumbnailIDs.removeAll()
        thumbnails.seed(thumb, url: url, pixels: Int(320 * size.scale))
        items[i].thumb = thumb
        refreshThumbnails(force: true)
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = displayItems.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        thumbnails.invalidate(); lastThumbnailIDs.removeAll()
        for i in items.indices { items[i].thumb = nil }
        refreshThumbnails()
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            // Tucked away, nobody sees the sway; a gust would still re-render
            // every view that watches the line.
            if self.revealed && !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func syncHistory() {
        if library != nil { reloadFromLibrary(); return }
        let paths = Set(history.entries.map(\.path))
        items.removeAll { !paths.contains($0.url.standardizedFileURL.path) && !$0.falling }
        sanitizeSelection()
        setScrollOffset(scrollOffset)
    }

    private func reloadFromLibrary() {
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let updated = history.entries.map { entry in
            var item = previous[entry.id] ?? Pegged(id: entry.id, url: entry.url, thumb: nil)
            item.url = entry.url; item.pinned = entry.pinned; item.originalPath = entry.originalPath
            item.title = entry.title
            item.managedCopy = history.files.isAppCopy(entry.url)
            return item
        }
        guard updated != items else { return }
        items = updated
        arrivalIDs.formIntersection(Set(items.map(\.id)))
        lastThumbnailIDs.removeAll(); sanitizeSelection(); setScrollOffset(scrollOffset)
    }

    func consumeArrival(_ id: UUID) -> Bool { arrivalIDs.remove(id) != nil }

    private func refreshThumbnails(force: Bool = false) {
        let displayed = displayItems
        let range = Layout.visibleRange(count: displayed.count, width: viewportWidth, offset: scrollOffset)
        let visible = range.map { displayed[$0] }
        let visibleIDs = Set(visible.map(\.id)), pixels = Int(320 * size.scale)
        guard force || visibleIDs != lastThumbnailIDs || pixels != lastThumbnailPixels else { return }
        lastThumbnailIDs = visibleIDs; lastThumbnailPixels = pixels
        var updated = items, changed = false
        for index in updated.indices {
            let image = visibleIDs.contains(updated[index].id) ? thumbnails.image(for: updated[index].url, pixels: pixels) : nil
            if updated[index].thumb !== image { updated[index].thumb = image; changed = true }
        }
        if changed { items = updated }
        thumbnails.request(visible.map(\.url), pixels: pixels)
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }


}

/// Screen recordings, as macOS saves them.
func isRecordingFile(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    guard let cg = decodeThumbnail(url, maxPixels: maxPixels) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

func decodeThumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
    if isRecordingFile(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return cg
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return cg
}
