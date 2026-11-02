import AppKit
import Combine

@MainActor final class LibraryModel: ObservableObject {
    let store: LibraryStore
    let copyPasteboard: NSPasteboard
    let keyboardBindings: KeyboardBindings
    @Published private(set) var query = LibraryQuery()
    @Published private(set) var ids = [UUID]()
    @Published private(set) var selectedIDs = Set<UUID>()
    @Published private(set) var focusedID: UUID?
    @Published private(set) var collections = [LibraryCollection]()
    @Published private(set) var tags = [LibraryTag]()
    @Published private(set) var loading = false
    @Published private(set) var notice: String?
    @Published private(set) var copiedIDs = Set<UUID>()
    @Published private(set) var imageSearchStatus = ""
    @Published var listMode = false
    @Published var inspectorVisible = true
    @Published var search = "" { didSet { debounceSearch() } }
    @Published var draftTitle = "" { didSet { scheduleSave() } }
    @Published var draftText = "" { didSet { scheduleSave() } }
    @Published var draftNote = "" { didSet { scheduleSave() } }
    @Published private(set) var inspected: LibraryRecord?
    @Published private(set) var inspectedCollections = [LibraryCollection]()
    @Published private(set) var inspectedTags = [LibraryTag]()
    var columns = 4
    var onPreview: ((UUID) -> Void)?
    var onSearchFocus: (() -> Void)?
    var onSearchEscape: (() -> Bool)?
    var onContentFocus: (() -> Void)? { didSet { onContentFocusReady = nil } }
    var onContentFocusReady: (() -> Bool)?
    var onInspectorFocusRequested: (() -> Void)?
    var onFocusNextPane: (() -> Void)?
    var onFocusPreviousPane: (() -> Void)?
    var onSearchNavigation: ((NSEvent) -> Bool)?
    var onFinishEditor: (() -> Bool)?
    var onNewFolderRequested: (() -> Void)?
    var onEditPreviewRequested: ((KeyboardAction, UUID) -> Void)?
    var onKeyboardSelectionCompleted: ((UUID) -> Void)?
    var onTagRequested: (() -> Void)?
    var onPinToFolderRequested: (([UUID]) -> Void)?
    var onNameAndPinRequested: ((UUID) -> Void)?
    var onNameAndPinBatchRequested: (([UUID]) -> Void)?
    var onPasteRequested: (([UUID]) -> Void)?
    var onImageTextCopyRequested: ((UUID) -> Void)?
    var onCommandsRequested: (() -> Void)?
    var onSelectionReveal: ((UUID) -> Void)?
    var onRecordsChanged: (([UUID]) -> Void)?
    var onVisibleLinks: (([UUID]) -> Void)?
    var thumbnailStats: (() -> ThumbnailStore.Stats?)?
    var collectionStats: (() -> (configurations: Int, refreshes: Int)?)?
    var onExportRequested: (() -> Void)?
    var onTrashRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onFlushPreview: () -> Bool = { true }
    private var flushingPreview = false
    private var subscription: AnyCancellable?
    private var noticeSubscription: AnyCancellable?
    private var searchSubscription: AnyCancellable?
    private var imageStatusSubscription: AnyCancellable?
    private(set) var updatesSuspended = false
    private(set) var reloadCount = 0
    private var resetOnResume = false
    private var queryGeneration = 0
    private var pendingQuery: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var loadingDraft = false
    private var dirty = false
    private var anchor: UUID?
    private var indices = [UUID: Int]()
    private var pages = [Int: [LibraryCardSummary]]()
    private var pageOrder = [Int]()
    private var wantedPages = [Int]()
    private var runningPages = Set<Int>()
    private var feedbackGeneration = 0
    private(set) var contentFocusPending = false
    private var pendingKeyboardSelection: (id: UUID?, query: LibraryQuery)?
    private struct PendingDetailsSelection {
        let id: UUID
        let query: LibraryQuery
        let mayBroaden: Bool
    }
    private var pendingDetailsSelection: PendingDetailsSelection?
    static let pageSize = 80
    var cachedSummaryCount: Int { pages.values.reduce(0) { $0 + $1.count } }
    var pendingPageCount: Int { runningPages.count }
    init(store: LibraryStore, copyPasteboard: NSPasteboard? = nil) {
        self.store = store
        keyboardBindings = KeyboardBindings(defaults: store.defaults)
        self.copyPasteboard = copyPasteboard ?? .general
        listMode = store.defaults.bool(forKey: "libraryListMode")
        inspectorVisible = store.defaults.object(forKey: "libraryInspectorVisible") as? Bool ?? true
        subscription = store.$revision.dropFirst().sink { [weak self] _ in self?.reload() }
        noticeSubscription = store.$notice.dropFirst().sink { [weak self] in if let notice = $0 { self?.notice = notice } }
        searchSubscription = store.$searchRevision.dropFirst().sink { [weak self] _ in guard let self, !self.search.isEmpty else { return }; self.reload() }
        imageStatusSubscription = store.$imageSearchStatus.sink { [weak self] status in
            guard let self, !self.updatesSuspended, self.imageSearchStatus != status else { return }
            self.imageSearchStatus = status
        }
        reload()
    }
    var title: String {
        switch query.scope {
        case .saved: L("My library"); case .favorites: L("Favorites"); case .unorganized: L("Unorganized")
        case .recent, .shelf: L("Recent copies"); case .trash: L("Trash")
        case let .collection(id): folderPath(id) ?? L("Folder")
        case let .tag(id): "#" + (tags.first { $0.id == id }?.name ?? L("Tag"))
        }
    }
    /// A subfolder reads "Parent / Middle / Child" (the whole parent chain, cycle-safe), as on Windows.
    private func folderPath(_ id: UUID) -> String? {
        guard collections.contains(where: { $0.id == id }) else { return nil }
        var names: [String] = [], visited = Set<UUID>(), next: UUID? = id
        while let current = next, visited.insert(current).inserted, let folder = collections.first(where: { $0.id == current }) {
            names.insert(folder.name, at: 0); next = folder.parentID
        }
        return names.joined(separator: " / ")
    }
    func clearNotice() { notice = nil; store.notice = nil }
    func report(_ message: String) { notice = message }
    /// Explicit keyboard entry is distinct from keeping a selection visible.
    /// In particular, background packets and sidebar browsing never steal focus.
    @discardableResult func focusContent() -> Bool {
        guard flushEdits() else { return false }
        pendingDetailsSelection = nil
        pendingQuery?.cancel(); pendingQuery = nil
        let searchChanged = applyPendingSearch()
        contentFocusPending = true
        if searchChanged { reload(reset: true) }
        if loading { if let ready = onContentFocusReady { _ = ready() } else { onContentFocus?() } }
        else { finishContentFocus() }
        return true
    }
    func cancelContentFocus() { contentFocusPending = false; pendingDetailsSelection = nil }
    func finishContentFocus() {
        guard contentFocusPending, !updatesSuspended, !loading else { return }
        if focusedID.flatMap({ indices[$0] }) == nil, let first = ids.first { _ = select(first) }
        if let ready = onContentFocusReady { if ready() { contentFocusPending = false } }
        else if let focus = onContentFocus { contentFocusPending = false; focus() }
    }
    private func finishKeyboardSelection() {
        guard let pending = pendingKeyboardSelection else { return }
        pendingKeyboardSelection = nil
        var expected = pending.query, actual = query
        expected.visualIDs = []; actual.visualIDs = []
        guard expected == actual else { return }
        if let id = pending.id, indices[id] != nil { if select(id) { onKeyboardSelectionCompleted?(id) } }
        else if let id = ids.first { if select(id) { onKeyboardSelectionCompleted?(id) } }
    }
    /// Keep capture and indexing in the shared store alive, but stop work for a
    /// closed Library. In-flight read completions are discarded by generation.
    @discardableResult func suspendUpdates() -> Bool {
        guard !updatesSuspended else { return true }
        guard flushEdits() else { return false }
        updatesSuspended = true; queryGeneration += 1; pendingDetailsSelection = nil; contentFocusPending = false; pendingKeyboardSelection = nil
        pendingQuery?.cancel(); pendingQuery = nil
        pages.removeAll(); pageOrder.removeAll(); wantedPages.removeAll(); runningPages.removeAll()
        return true
    }
    func resumeUpdates() {
        guard flushEdits() else { return }
        updatesSuspended = false
        let searchChanged = applyPendingSearch(), reset = resetOnResume || searchChanged
        resetOnResume = false
        if imageSearchStatus != store.imageSearchStatus { imageSearchStatus = store.imageSearchStatus }
        reload(reset: reset)
    }
    @discardableResult private func applyPendingSearch() -> Bool {
        guard query.search != search else { return false }
        if query.search.isEmpty && !search.isEmpty && query.sort == .newest { query.sort = .relevance }
        if search.isEmpty && query.sort == .relevance { query.sort = .newest }
        query.search = search; return true
    }
    private func debounceSearch() {
        pendingQuery?.cancel()
        guard !updatesSuspended else { resetOnResume = resetOnResume || query.search != search; return }
        guard query.search != search else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.updatesSuspended, self.query.search != self.search, self.flushEdits() else { return }
            self.applyPendingSearch(); self.reload(reset: true)
        }
        pendingQuery = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    func changeScope(_ value: LibraryQuery.Scope) {
        guard flushEdits() else { return }; query.scope = value; reload(reset: true)
    }
    func setKind(_ value: LibraryKind?) { guard flushEdits() else { return }; query.kind = value; reload(reset: true) }
    func setSort(_ value: LibraryQuery.Sort) { guard flushEdits() else { return }; query.sort = value; reload() }
    func setSearchMode(_ value: LibraryQuery.SearchMode) { guard flushEdits() else { return }; query.searchMode = value; reload(reset: true) }
    func setFavorites(_ value: Bool) { guard flushEdits() else { return }; query.favoritesOnly = value; reload(reset: true) }
    var showingPinnedOnly: Bool { query.scope == .favorites || query.favoritesOnly }
    func togglePinnedOnly() {
        guard flushEdits() else { return }
        if query.scope == .favorites { query.scope = .saved; query.favoritesOnly = false; reload(reset: true) }
        else { setFavorites(!query.favoritesOnly) }
    }
    func setDays(_ value: Int?) { guard flushEdits() else { return }; query.days = value; reload(reset: true) }
    func setDomain(_ value: String) { guard flushEdits() else { return }; query.domain = value.trimmingCharacters(in: .whitespacesAndNewlines); reload(reset: true) }
    func toggleTagFilter(_ id: UUID) { guard flushEdits() else { return }; if !query.tagIDs.insert(id).inserted { query.tagIDs.remove(id) }; reload(reset: true) }
    func clearFilters() {
        guard flushEdits() else { return }
        query.kind = nil; query.favoritesOnly = false; query.tagIDs.removeAll(); query.days = nil; query.domain = ""
        search = ""; applyPendingSearch(); pendingQuery?.cancel(); pendingQuery = nil
        query.searchMode = .all; reload(reset: true)
    }
    /// A command can refer to a shelf item outside this Library's last filter.
    /// Keep a matching view intact, otherwise reveal it in the appropriate
    /// saved/recent/Trash scope after the current generation finishes loading.
    func revealItemDetails(_ id: UUID) {
        guard flushEdits(), let record = try? store.item(id) else { return }
        inspectorVisible = true
        if indices[id] != nil {
            if loading { pendingDetailsSelection = PendingDetailsSelection(id: id, query: query, mayBroaden: true) }
            else { _ = select(id); onInspectorFocusRequested?() }
        } else { broadenDetailsQuery(record) }
    }
    private func broadenDetailsQuery(_ record: LibraryRecord) {
        query = LibraryQuery(scope: record.deletedAt != nil ? .trash : record.retainedAt != nil ? .saved : .recent)
        search = ""; pendingQuery?.cancel(); pendingQuery = nil
        pendingDetailsSelection = PendingDetailsSelection(id: record.id, query: query, mayBroaden: false)
        reload(reset: true)
    }
    private func finishDetailsSelection() {
        guard let pending = pendingDetailsSelection else { return }
        pendingDetailsSelection = nil
        var expected = pending.query, actual = query
        // Image-analysis results may refresh independently of the user's view.
        expected.visualIDs = []; actual.visualIDs = []
        guard expected == actual, search == query.search else { return }
        if indices[pending.id] != nil {
            if select(pending.id) { inspectorVisible = true; onInspectorFocusRequested?() }
        } else if pending.mayBroaden, let record = try? store.item(pending.id) {
            // At most one broader reload: an in-flight filtered query may have
            // removed the item from the old IDs observed when the command ran.
            broadenDetailsQuery(record)
        }
    }
    func reload(reset: Bool = false) {
        guard !updatesSuspended else { resetOnResume = resetOnResume || reset; return }
        reloadCount += 1
        queryGeneration += 1; let generation = queryGeneration
        let changes = store.changedIDs
        runningPages.removeAll()
        if reset || changes.isEmpty { pages.removeAll(); pageOrder.removeAll() }
        else { for id in changes { if let index = indices[id] { pages[index / Self.pageSize] = nil } } }
        loading = true
        do {
            let folders = try store.collections(), labels = try store.tags()
            if collections != folders { collections = folders }
            if tags != labels { tags = labels }
            // A removed tag would stay as a filter with no chip, hiding every item.
            let live = Set(labels.map(\.id))
            if !query.tagIDs.isSubset(of: live) { query.tagIDs.formIntersection(live) }
        } catch { notice = error.localizedDescription }
        store.resolveImageSearch(query) { [weak self] resolved in
          guard let self, generation == self.queryGeneration else { return }
          self.query = resolved
          self.store.queryIDsAsync(resolved) { [weak self] result in
            guard let self, generation == self.queryGeneration else { return }
            self.loading = false
            switch result {
            case let .success(ids):
                let differentIDs = self.ids != ids
                if differentIDs { self.pages.removeAll(); self.pageOrder.removeAll() }
                if differentIDs {
                    self.ids = ids; self.indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                    let selected = self.selectedIDs.intersection(Set(ids))
                    if selected != self.selectedIDs { self.selectedIDs = selected }
                }
                if let id = self.focusedID, self.indices[id] == nil, self.flushEdits() {
                    self.focusedID = nil; self.anchor = nil; _ = self.inspect(nil)
                }
                if reset { self.selectedIDs.removeAll(); self.focusedID = nil; self.anchor = nil; _ = self.inspect(nil) }
                if self.wantedPages.isEmpty || differentIDs || reset { self.requestVisible(Array(ids.prefix(Self.pageSize))) } else { self.schedulePages() }
                self.onRecordsChanged?(ids)
                // Revisions update sidebar metadata without destroying an editor.
                if !self.dirty, let id = self.focusedID { _ = self.inspect(id) }
                self.finishDetailsSelection()
                self.finishKeyboardSelection()
                self.finishContentFocus()
            case let .failure(error): self.pendingDetailsSelection = nil; self.notice = error.localizedDescription
            }
          }
        }
    }
    func summary(_ id: UUID) -> LibraryRecord? {
        cardSummary(id)?.record
    }
    func index(of id: UUID) -> Int? { indices[id] }
    func cardSummary(_ id: UUID) -> LibraryCardSummary? {
        guard let index = indices[id], let page = pages[index / Self.pageSize] else { return nil }
        let offset = index % Self.pageSize
        guard offset < page.count, page[offset].record.id == id else { return nil }
        return page[offset]
    }
    func requestVisible(_ ids: [UUID]) {
        guard !updatesSuspended else { return }
        var seen = Set<Int>()
        wantedPages = ids.compactMap { indices[$0].map { $0 / Self.pageSize } }.filter { seen.insert($0).inserted }
        schedulePages()
    }
    private func schedulePages() {
        guard !updatesSuspended else { return }
        for page in wantedPages {
            guard runningPages.count < 2 else { return }
            guard pages[page] == nil, !runningPages.contains(page) else { continue }
            runningPages.insert(page); let generation = queryGeneration
            store.cardSummariesAsync(query, limit: Self.pageSize, offset: page * Self.pageSize) { [weak self] result in
                guard let self, generation == self.queryGeneration else { return }
                self.runningPages.remove(page)
                switch result {
                case let .success(summaries):
                    // Grid summaries stay small even when a note is one megabyte.
                    self.pages[page] = summaries.map { summary in var value = summary; value.record.text = summary.record.text.map { String($0.prefix(500)) }; value.record.note = ""; return value }
                    self.pageOrder.removeAll { $0 == page }; self.pageOrder.append(page)
                    while self.pageOrder.count > 12 { self.pages.removeValue(forKey: self.pageOrder.removeFirst()) }
                    let records = summaries.map(\.record)
                    self.onRecordsChanged?(records.map(\.id)); self.onVisibleLinks?(records.filter { $0.kind == .link }.map(\.id))
                case let .failure(error): self.notice = error.localizedDescription; self.wantedPages.removeAll { $0 == page }
                }
                self.schedulePages()
            }
        }
    }
    @discardableResult func select(_ id: UUID, toggle: Bool = false, extending: Bool = false, preservingSelection: Bool = false) -> Bool {
        guard let target = indices[id], id == focusedID || flushEdits() else { return false }
        pendingDetailsSelection = nil
        if extending, let anchor, let start = indices[anchor] { selectedIDs = Set(ids[min(start,target)...max(start,target)]) }
        else if toggle { if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }; anchor = id }
        else if !preservingSelection || !selectedIDs.contains(id) { selectedIDs = [id]; anchor = id }
        focusedID = id; if inspected?.id != id { _ = inspect(id) }; onSelectionReveal?(id); return true
    }
    func selectAll() { selectedIDs = Set(ids); if focusedID == nil, let first = ids.first { focusedID = first; anchor = first; _ = inspect(first) } }
    func acceptNativeSelection(_ selection: Set<UUID>, focused: UUID?) -> Bool {
        guard focused == focusedID || flushEdits() else { return false }
        selectedIDs = selection.intersection(Set(ids)); focusedID = focused; anchor = focused
        if inspected?.id != focused { _ = inspect(focused) }; return true
    }
    func move(_ delta: Int, extending: Bool = false) {
        guard !ids.isEmpty else { return }
        let target = focusedID.flatMap { indices[$0] }.map { max(0, min(ids.count - 1, $0 + delta)) } ?? 0
        _ = select(ids[target], extending: extending)
    }
    func moveVertically(_ direction: Int, extending: Bool = false) {
        guard !ids.isEmpty else { return }
        guard let focusedID, let index = indices[focusedID] else { _ = select(ids[0]); return }
        let width = listMode ? 1 : max(1, columns)
        let row = index / width, column = index % width, lastRow = (ids.count - 1) / width
        let targetRow = max(0, min(lastRow, row + direction))
        guard targetRow != row else { return }
        _ = select(ids[min(ids.count - 1, targetRow * width + column)], extending: extending)
    }
    func moveToBoundary(last: Bool) { guard let id = last ? ids.last : ids.first else { return }; _ = select(id) }
    func movePage(_ direction: Int) {
        guard !ids.isEmpty else { return }
        let index = focusedID.flatMap { indices[$0] } ?? 0
        _ = select(ids[max(0, min(ids.count - 1, index + direction * 9))])
    }
    var actionIDs: [UUID] {
        if selectedIDs.isEmpty { return focusedID.map { [$0] } ?? [] }
        if selectedIDs.count == ids.count { return ids }
        return selectedIDs.filter { indices[$0] != nil }.sorted { indices[$0]! < indices[$1]! }
    }
    func copy(to board: NSPasteboard? = nil) {
        guard flushEdits(), !actionIDs.isEmpty else { return }
        copyRecords(actionIDs, to: board ?? copyPasteboard)
    }
    func copyCurrent(_ id: UUID) { guard flushEdits() else { return }; copyRecords([id], to: copyPasteboard) }
    func dragItems(_ id: UUID) -> [ShelfDragItem] {
        guard flushEdits(), selectedIDs.contains(id) || select(id) else { return [] }
        do { return try LibraryTransfer.dragItems(store.records(actionIDs), store: store) }
        catch { notice = error.localizedDescription; return [] }
    }
    private func copyRecords(_ selected: [UUID], to board: NSPasteboard) {
        perform {
            let ids = selected, items = try LibraryTransfer.pasteboardItems(store.records(ids))
            guard ClipboardTransfer.write(items, to: board) else { throw HistoryFiles.Failure.unsafeFile }
            try store.markCopied(ids)
            copiedIDs = Set(ids); feedbackGeneration += 1; let generation = feedbackGeneration
            notice = ids.count == 1 ? L("Copied") : String(format: L("%d items copied"), ids.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in if self?.feedbackGeneration == generation { self?.copiedIDs.removeAll() } }
        }
    }
    func favorite() { guard flushEdits() else { return }; perform { try store.toggleFavorite(actionIDs) } }
    func retain() { guard flushEdits() else { return }; perform { try store.retain(actionIDs) } }
    func trash() { trashSelection() }
    func trashSelection(_ explicitIDs: [UUID]? = nil) {
        guard query.scope != .trash, flushEdits() else { return }
        let targets = explicitIDs ?? actionIDs, removed = Set(targets)
        guard !targets.isEmpty else { return }
        let pivot = focusedID.flatMap { indices[$0] } ?? 0
        let next = ids.dropFirst(pivot).first { !removed.contains($0) }
            ?? ids.prefix(pivot).reversed().first { !removed.contains($0) }
        pendingKeyboardSelection = (next, query)
        do { try store.trashUndoably(targets) }
        catch { pendingKeyboardSelection = nil; report(error.localizedDescription) }
    }
    var canUndoTrash: Bool { store.canUndoTrash }
    func undoTrash() {
        guard flushEdits() else { return }
        do {
            let restored = try store.undoTrash()
            guard let first = restored.first else { report(L("Nothing to undo")); return }
            pendingKeyboardSelection = (first, query)
            if !loading { finishKeyboardSelection() }
        } catch { report(error.localizedDescription) }
    }
    func restore() {
        let targets = actionIDs
        guard !targets.isEmpty else { return }
        // The restored items leave Trash: select the first one that remains, as Windows does.
        if query.scope == .trash { pendingKeyboardSelection = (nil, query) }
        do { try store.restore(targets) }
        catch { pendingKeyboardSelection = nil; report(error.localizedDescription) }
    }
    func assign(_ folder: UUID, moving: Bool = false) {
        guard flushEdits() else { return }
        var source: UUID?; if moving, case let .collection(id) = query.scope { source = id }
        perform { try store.assign(actionIDs, to: folder, movingFrom: source) }
    }
    func addTag(_ name: String) { guard flushEdits() else { return }; perform { try store.addTag(name, to: actionIDs) } }
    /// Remove a folder with its subfolders. Only a view of that subtree falls back to My library, as on Windows.
    func removeFolder(_ id: UUID) {
        guard flushEdits() else { return }
        let removed = Set(((try? store.collections()) ?? collections).filter { $0.id == id || $0.parentID == id }.map(\.id))
        var done = false
        perform { try store.removeCollection(id); done = true }
        if done, case let .collection(current) = query.scope, removed.contains(current) { changeScope(.saved) }
    }
    func unassign(_ folder: UUID) { guard flushEdits(), let id = inspected?.id else { return }; perform { try store.unassign(id, from: folder) } }
    func removeTag(_ tag: UUID) { guard flushEdits(), let id = inspected?.id else { return }; perform { try store.removeTag(tag, from: id) } }
    func open() { guard let id = focusedID, let record = try? store.item(id), let url = record.linkURL ?? record.fileURL else { return }; NSWorkspace.shared.open(url) }
    func newNote() { guard flushEdits() else { return }; perform { let note = try store.createNote(); query = LibraryQuery(scope: .saved, kind: .text); search = ""; pendingQuery?.cancel(); inspectorVisible = true; focusedID = note.id; selectedIDs = [note.id]; _ = inspect(note.id); pendingDetailsSelection = PendingDetailsSelection(id: note.id, query: query, mayBroaden: false); reload() } }
    func perform(_ action: () throws -> Void) { do { try action() } catch { notice = error.localizedDescription } }
    @discardableResult private func inspect(_ id: UUID?) -> Bool {
        if inspected?.id != id, !flushEdits() { return false }
        loadingDraft = true; defer { loadingDraft = false }
        inspected = id.flatMap { try? store.item($0) }
        inspectedCollections = id.flatMap { try? store.collections(for: $0) } ?? []
        inspectedTags = id.flatMap { try? store.tags(for: $0) } ?? []
        draftTitle = inspected?.title ?? ""; draftText = inspected?.text ?? ""; draftNote = inspected?.note ?? ""
        dirty = false; return true
    }
    private func scheduleSave() {
        guard !loadingDraft, inspected != nil else { return }
        dirty = true; pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flushEdits() }; pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    @discardableResult func flushEdits() -> Bool {
        if !flushingPreview {
            flushingPreview = true
            defer { flushingPreview = false }
            guard onFlushPreview() else { return false }
        }
        pendingSave?.cancel(); pendingSave = nil
        guard dirty, let record = inspected else { return true }
        do {
            let title = draftTitle, text = draftText, note = draftNote
            // Clear before publishing the transaction, so synchronous observers
            // cannot attempt to save the same draft recursively.
            dirty = false
            try store.update(record.id) { $0.title = title; $0.note = note; if $0.kind == .text { $0.text = text } }
            return true
        } catch { dirty = true; notice = L("Changes could not be saved; keep this draft open"); return false }
    }
    func handleKey(_ event: NSEvent, editing: Bool) -> Bool {
        let action = keyboardBindings.action(for: event, in: .library)
        if action == .commandPalette, !editing || !event.modifierFlags.intersection([.command, .control]).isEmpty { return perform(.commandPalette) }
        if action == .search, !editing || !event.modifierFlags.intersection([.command, .control]).isEmpty { return perform(.search) }
        let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let functionKey = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90].contains(Int(event.keyCode))
        if action == .focusNextPane || action == .focusPreviousPane, !editing || modified || functionKey { return perform(action!) }
        if action == .newNote || action == .newFolder, !editing || modified { return perform(action!) }
        if editing, onSearchNavigation?(event) == true { return true }
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty, onSearchEscape?() == true { return true }
        if editing, event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty, onFinishEditor?() == true { return true }
        guard !editing, let action else { return false }
        if loading && contentFocusPending && ![.search, .commandPalette, .close].contains(action) { return true }
        return perform(action)
    }
    /// Execute a chosen action without manufacturing a keyboard event. Native
    /// editor guards stay in handleKey; explicit commands share the same route.
    @discardableResult func perform(_ action: KeyboardAction) -> Bool {
        switch action {
        case .paste: if flushEdits() { onPasteRequested?(actionIDs) }
        case .copyImageText: if let focusedID { onImageTextCopyRequested?(focusedID) }
        case .commandPalette: cancelContentFocus(); onCommandsRequested?()
        case .focusNextPane: cancelContentFocus(); onFocusNextPane?()
        case .focusPreviousPane: cancelContentFocus(); onFocusPreviousPane?()
        case .undoTrash: undoTrash()
        case .newNote: newNote()
        case .newFolder: if flushEdits() { onNewFolderRequested?() }
        case .search: cancelContentFocus(); onSearchFocus?()
        case .selectAll: selectAll()
        case .copy: copy()
        case .pin: favorite()
        case .pinToFolder: if flushEdits(), !actionIDs.isEmpty { onPinToFolderRequested?(actionIDs) }
        case .nameAndPin:
            // actionIDs uses the current filtered/sorted visible order, never Set order.
            if flushEdits(), !actionIDs.isEmpty { onNameAndPinBatchRequested?(actionIDs) }
        case .pinnedOnly: togglePinnedOnly(); _ = focusContent()
        case .open: open()
        case .allTypes: setKind(nil); _ = focusContent()
        case .images: setKind(.image); _ = focusContent()
        case .texts: setKind(.text); _ = focusContent()
        case .links: setKind(.link); _ = focusContent()
        case .tag: onTagRequested?()
        case .export: onExportRequested?()
        case .trash: trashSelection()
        case .editText, .markup, .cropImage:
            if actionIDs.count == 1, let id = actionIDs.first, let record = try? store.item(id), record.deletedAt == nil,
               (action == .editText ? record.kind == .text : record.kind == .image) { onEditPreviewRequested?(action, id) }
        case .previous: move(-1)
        case .next: move(1)
        case .up: moveVertically(-1)
        case .down: moveVertically(1)
        case .first: moveToBoundary(last: false)
        case .last: moveToBoundary(last: true)
        case .previousPage: movePage(-1)
        case .nextPage: movePage(1)
        case .extendPrevious: move(-1, extending: true)
        case .extendNext: move(1, extending: true)
        case .extendUp: moveVertically(-1, extending: true)
        case .extendDown: moveVertically(1, extending: true)
        case .preview: if let id = focusedID { onPreview?(id) }
        case .close: guard let onCloseRequested else { return false }; onCloseRequested()
        default: return false
        }
        return true
    }
}
