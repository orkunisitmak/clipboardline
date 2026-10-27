import AppKit

/// Previews act on their current item, independently of batch selection.
@MainActor
final class ShelfPreviewSession {
    let line: Line
    private(set) var shelf: Shelf
    private(set) var currentID: UUID
    init(line: Line, shelf: Shelf, id: UUID) { self.line = line; self.shelf = shelf; currentID = id }
    var ids: [UUID] {
        ids(for: shelf)
    }
    private func ids(for shelf: Shelf) -> [UUID] {
        switch shelf { case .texts: line.texts.displayEntries.map(\.id); case .links: line.links.displayEntries.map(\.id)
        case .images: line.displayItems.filter { !$0.falling && !$0.isRecording }.map(\.id) }
    }
    var hasCurrentItem: Bool { ids.contains(currentID) }
    var position: String { "\(ids.firstIndex(of: currentID).map { $0 + 1 } ?? 0) / \(ids.count)" }
    var pinned: Bool {
        switch shelf { case .texts: line.texts.entries.first { $0.id == currentID }?.pinned == true
        case .links: line.links.entries.first { $0.id == currentID }?.favorite == true
        case .images: line.items.first { $0.id == currentID }?.pinned == true }
    }
    var uploadedURL: String? {
        switch shelf { case .texts: line.texts.entries.first { $0.id == currentID }?.uploadedURL
        case .links: line.links.entries.first { $0.id == currentID }?.uploadedURL
        case .images: line.items.first { $0.id == currentID }?.uploadedURL }
    }
    var text: String? { line.texts.entries.first { $0.id == currentID }?.text }
    var url: URL? { line.items.first { $0.id == currentID }?.url }
    var linkRecord: LibraryRecord? { line.links.entries.first { $0.id == currentID } }
    @discardableResult func move(_ delta: Int) -> Bool {
        let values = ids
        guard !values.isEmpty else { return false }
        let index = values.firstIndex(of: currentID) ?? 0
        currentID = values[max(0, min(values.count - 1, index + delta))]
        selectCurrent(); return true
    }
    @discardableResult func moveToBoundary(last: Bool) -> Bool {
        guard let id = last ? ids.last : ids.first else { return false }
        currentID = id; selectCurrent(); return true
    }
    @discardableResult func movePage(_ delta: Int) -> Bool {
        line.focusShelf(shelf, requestFocus: false)
        guard let id = line.moveShelfPage(delta, allowedIDs: Set(ids)) else { return false }
        currentID = id
        return true
    }
    @discardableResult func removeCurrent() -> Bool {
        guard let library = line.library, let index = ids.firstIndex(of: currentID) else { return false }
        do { try library.removeFromShelf([currentID]) }
        catch { line.notice = error.localizedDescription; return false }
        clearSelection()
        if !ids.isEmpty { currentID = ids[min(index, ids.count - 1)]; selectCurrent() }
        return true
    }
    @discardableResult func undoRemoval() -> Bool {
        guard let library = line.library else { return false }
        let restored: [UUID]
        do { restored = try library.undoShelfRemoval() }
        catch { line.notice = error.localizedDescription; return false }
        guard !restored.isEmpty else { return false }
        let kinds = Set(restored.compactMap { try? library.item($0)?.kind })
        line.refreshShelfSearchAfterUndo(kinds)
        let rows = [shelf] + line.presentation.shelves.filter { $0 != shelf }
        for row in rows where line.presentation.shelves.contains(row) {
            if let id = restored.first(where: { ids(for: row).contains($0) }) {
                shelf = row; currentID = id; clearSelection(); selectCurrent(); return true
            }
        }
        return false
    }
    private func clearSelection() {
        line.cancelSelection(); line.texts.cancelSelection(); line.links.cancelSelection()
    }
    @discardableResult func moveShelf(_ delta: Int, canPresent: (Shelf, UUID) -> Bool = { _, _ in true }) -> Bool {
        guard delta != 0, let row = line.presentation.shelves.firstIndex(of: shelf) else { return false }
        let column = ids.firstIndex(of: currentID) ?? 0
        let step = delta < 0 ? -1 : 1
        var next = row + step
        while line.presentation.shelves.indices.contains(next) {
            let destination = line.presentation.shelves[next], values = ids(for: destination)
            if !values.isEmpty {
                let id = values[min(column, values.count - 1)]
                // Rendering may fail (for example, a deleted image). Keep the
                // original session and selection until the target is ready.
                guard canPresent(destination, id) else { return false }
                shelf = destination; currentID = id
                line.cancelSelection(); line.texts.cancelSelection(); line.links.cancelSelection()
                selectCurrent(); return true
            }
            next += step
        }
        return false
    }
    @discardableResult func copy() -> Bool { switch shelf { case .texts: line.texts.copy(currentID); case .links: line.links.copy(currentID); case .images: line.copy(currentID) } }
    func saveText(_ text: String) -> Bool { line.texts.updateText(currentID, to: text) }
    @discardableResult func togglePin() -> Bool {
        let previous = ids.firstIndex(of: currentID) ?? 0
        switch shelf { case .texts: line.texts.togglePin(currentID); case .links: line.links.togglePin(currentID); case .images: line.pinFromUI(currentID) }
        return reconcile(previousIndex: previous)
    }
    @discardableResult func toggleFavorites() -> Bool {
        if shelf == .texts { line.texts.setFavoritesOnly(!line.texts.favoritesOnly) }
        else if shelf == .links { line.links.setFavoritesOnly(!line.links.favoritesOnly) }
        else { line.setFavoritesOnly(!line.favoritesOnly) }
        return reconcile(previousIndex: 0)
    }
    private func reconcile(previousIndex: Int) -> Bool {
        guard !ids.isEmpty else { return false }
        if !ids.contains(currentID) { currentID = ids[min(previousIndex, ids.count - 1)] }
        selectCurrent(); return true
    }
    func selectCurrent() {
        line.focusShelf(shelf, requestFocus: false)
        if shelf == .texts { line.texts.select(currentID, width: line.viewportWidth) }
        else if shelf == .links { line.links.select(currentID, width: line.viewportWidth) }
        else { line.select(currentID) }
    }
}
