import AppKit
import Combine

@MainActor final class LibraryPreviewController {
    let model: LibraryModel
    private(set) var currentID: UUID?
    private(set) var image: ImagePreview?
    private(set) var text: TextPreview?
    private(set) var link: LinkPreview?
    private(set) var empty: EmptyShelfPreview?
    var window: ActionPreviewPanel? { (image?.window ?? text?.window ?? link?.window ?? empty?.window) as? ActionPreviewPanel }
    var onBeforeMouseKeyFocus: (() -> Void)?
    private var generation = 0
    private var currentIndex = 0
    private var subscription: AnyCancellable?
    private var contentSubscription: AnyCancellable?
    init(model: LibraryModel) {
        self.model = model
        model.onKeyboardSelectionCompleted = { [weak self] id in
            guard let self, self.window != nil else { return }
            self.show(id)
        }
        subscription = model.$ids.dropFirst().receive(on: RunLoop.main).sink { [weak self] ids in
            guard let self else { return }
            if self.empty != nil {
                if let id = self.model.focusedID, ids.contains(id) { self.show(id) }
                else if let id = ids.first { _ = self.model.select(id); self.show(id) }
                return
            }
            guard let currentID = self.currentID else { return }
            if ids.contains(currentID) { self.updateControls() }
            else if self.text?.isEditing == true { self.updateControls() }
            else if !ids.isEmpty {
                let neighbor = ids[min(self.currentIndex, ids.count - 1)]
                _ = self.model.select(neighbor); self.show(neighbor)
            }
            else { self.showEmpty() }
        }
        // IDs deliberately stay quiet when result membership/order is stable.
        // Metadata and pin changes must still refresh the currently open preview.
        contentSubscription = model.store.$revision.dropFirst()
            .filter { [weak self] _ in self?.currentID != nil }
            .map { [weak store = model.store] _ in store?.changedIDs ?? [] }
            .receive(on: RunLoop.main).sink { [weak self] changed in
                guard let self, let id = self.currentID, changed.isEmpty || changed.contains(id) else { return }
                self.updateControls()
            }
    }
    @discardableResult func flush() -> Bool { (image?.flushEdits() ?? true) && (text?.flushEdits() ?? true) }
    func reportActionStatus(_ message: String) {
        image?.controls.position.stringValue = message
        text?.controls.position.stringValue = message
        link?.controls.position.stringValue = message
    }
    func close() { guard flush() else { return }; generation += 1; window?.close(); image = nil; text = nil; link = nil; empty = nil; currentID = nil }
    private func showEmpty() {
        guard let window, flush() else { return }
        generation += 1; let token = generation
        let preview = EmptyShelfPreview(window: window, keyboardBindings: model.keyboardBindings, message: L("No matching items"), undoAction: .undoTrash)
        preview.onUndo = { [weak model] in model?.undoTrash() }
        preview.onKey = { [weak self] event in
            guard let self, let action = self.model.keyboardBindings.action(for: event, in: .library) else { return false }
            if action == .undoTrash { self.model.undoTrash(); return true }
            if action == .commandPalette { self.model.onCommandsRequested?(); return true }
            return false
        }
        preview.onClose = { [weak self] in self?.didClose(token) }
        image?.scroll.endPan(); image = nil; text = nil; link = nil; currentID = nil; empty = preview
        window.makeKeyAndOrderFront(nil)
    }
    func show(_ id: UUID) {
        guard flush(), model.flushEdits(), let record = try? model.store.item(id), record.deletedAt == nil else { return }
        let previousID = currentID
        if record.kind == .text, let text { if previousID != id { text.replaceText(record.text ?? "") }; currentID = id; updateControls(); text.show(); return }
        if record.kind == .image, let image, let url = record.fileURL, !isRecordingFile(url) {
            guard previousID == id || image.replaceImage(url: url) else { return }; currentID = id; if previousID != id { wireImageMarkup(image, id: id) }; updateControls(); image.show(); return
        }
        if record.kind == .link, let link { link.replace(record); currentID = id; updateControls(); link.show(); return }
        let reusable = window
        image?.scroll.endPan(); image = nil; text = nil; link = nil; empty = nil
        currentID = id; generation += 1; let token = generation
        let controls: PreviewControls
        switch record.kind {
        case .text:
            let preview = TextPreview(text: record.text ?? "", copyPasteboard: model.copyPasteboard, keyboardBindings: model.keyboardBindings, window: reusable); text = preview; controls = preview.controls
            preview.window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            preview.onSave = { [weak self] value in
                guard let self, let id = self.currentID else { return false }
                do { try self.model.store.update(id) { $0.text = value }; return true } catch { return false }
            }
            preview.onKey = { [weak self] in self?.handle($0) ?? false }
            preview.onClose = { [weak self] in self?.didClose(token) }; wireMouseFocus(preview.window); preview.show()
        case .image:
            guard let url = record.fileURL else { reusable?.close(); model.perform { throw HistoryFiles.Failure.unsafeFile }; currentID = nil; return }
            if isRecordingFile(url) { reusable?.close(); QuickLook.shared.show([url], at: 0); currentID = nil; return }
            guard let preview = ImagePreview(url: url, keyboardBindings: model.keyboardBindings, window: reusable) else { reusable?.close(); model.perform { throw HistoryFiles.Failure.unsafeFile }; currentID = nil; return }
            image = preview; controls = preview.controls; wireImageMarkup(preview, id: id)
            preview.window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            preview.onKey = { [weak self] in self?.handle($0) ?? false }; preview.onClose = { [weak self] in self?.didClose(token) }; wireMouseFocus(preview.window); preview.show()
        case .link:
            let preview = LinkPreview(record: record, keyboardBindings: model.keyboardBindings, window: reusable); link = preview; controls = preview.controls
            preview.onKey = { [weak self] in self?.handle($0) ?? false }; preview.onClose = { [weak self] in self?.didClose(token) }; wireMouseFocus(preview.window); preview.show()
        }
        controls.onMove = { [weak self] in self?.move($0) }; controls.onCopy = { [weak self] in self?.copy() }; controls.onUpload = { [weak self] in self?.upload() }; controls.onPin = { [weak self] in self?.pin() }
        controls.onCommands = { [weak model] in model?.onCommandsRequested?() }
        updateControls()
    }
    private func wireMouseFocus(_ window: NSWindow) {
        (window as? ActionPreviewPanel)?.onBeforeMouseKeyFocus = { [weak self] in self?.onBeforeMouseKeyFocus?() }
    }
    @discardableResult func performNavigation(_ action: KeyboardAction) -> Bool {
        guard currentID != nil else { return false }
        switch action {
        case .previous: move(-1)
        case .next: move(1)
        case .up, .down:
            guard flush(), let id = currentID, model.select(id, preservingSelection: true) else { return false }
            model.moveVertically(action == .up ? -1 : 1)
            if let target = model.focusedID { show(target) }
        case .previousPage: move(-9)
        case .nextPage: move(9)
        case .first, .last:
            guard flush(), let id = action == .first ? model.ids.first : model.ids.last else { return false }
            guard model.select(id) else { return false }; show(id)
        default: return false
        }
        return true
    }
    private func wireImageMarkup(_ preview: ImagePreview, id: UUID) {
        guard let record = try? model.store.item(id), let source = record.markupSourceURL else { return }
        preview.configureMarkup(document: record.imageMarkup ?? ImageMarkupDocument(), sourceURL: source)
        preview.onSaveMarkup = { [weak self, weak preview] document in
            guard let self, let preview else { return false }
            do {
                let saved = try self.model.store.saveImageMarkup(id, document: document)
                if let source = saved.markupSourceURL, let rendered = saved.fileURL { preview.updateMarkupSource(source, renderedURL: rendered) }
                return true
            } catch { self.model.store.notice = error.localizedDescription; return false }
        }
    }

    private func didClose(_ token: Int) { guard token == generation else { return }; image = nil; text = nil; link = nil; empty = nil; currentID = nil; _ = model.focusContent() }
    private func move(_ delta: Int) {
        guard flush(), let id = currentID, !model.ids.isEmpty else { return }
        // An edited note can stop matching the current search. Keep its draft
        // until editing finishes, then browse from the vacated result position.
        let index = model.index(of: id)
        let destination = index.map { $0 + delta } ?? (delta < 0 ? currentIndex - 1 : currentIndex)
        let target = model.ids[max(0, min(model.ids.count - 1, destination))]
        _ = model.select(target); show(target)
    }
    private func copy() {
        guard flush(), let id = currentID else { return }
        model.copyCurrent(id)
        if model.copiedIDs.contains(id) { text?.flashCopied(); link?.flashCopied(); image?.controls.position.stringValue = L("Copied") }
    }
    private func upload() {
        guard flush(), let id = currentID else { return }
        model.uploadCurrent(id)
    }
    private func pin() { guard flush(), let id = currentID else { return }; model.perform { try model.store.toggleFavorite([id]) }; updateControls() }
    private func updateControls() {
        guard let id = currentID, let record = try? model.store.item(id) else { return }
        let index = model.index(of: id)
        currentIndex = index ?? currentIndex
        link?.replace(record)
        if let base = record.markupSourceURL, let rendered = record.fileURL { image?.updateMarkupSource(base, renderedURL: rendered) }
        let position = "\(index != nil ? String(currentIndex + 1) : "—") / \(model.ids.count)"
        let uploaded = record.uploadedURL != nil
        image?.controls.update(position: position, pinned: record.favorite, uploaded: uploaded); text?.controls.update(position: position, pinned: record.favorite, uploaded: uploaded); link?.controls.update(position: position, pinned: record.favorite, uploaded: uploaded)
    }
    private func handle(_ event: NSEvent) -> Bool {
        if image?.isMarkupEditing != true, text?.isEditing != true,
           let libraryAction = model.keyboardBindings.action(for: event, in: .library) {
            if libraryAction == .trash, let id = currentID {
                guard flush(), model.select(id, preservingSelection: true) else { return true }
                model.trashSelection([id]); return true
            }
            let imageMarkupUndo = image != nil && event.keyCode == 6 && event.modifierFlags.contains(.command)
            if libraryAction == .undoTrash, !imageMarkupUndo { model.undoTrash(); return true }
        }
        let context: KeyboardContext = text != nil ? .textPreview : link != nil ? .linkPreview : .imagePreview
        guard let action = model.keyboardBindings.action(for: event, in: context) else { return false }
        switch action {
        case .paste: if flush(), let id = currentID { model.onPasteRequested?([id]) }
        case .upload: upload()
        case .finishEditing: if model.keyboardBindings.matches(.paste, event: event), flush(), let id = currentID { model.onPasteRequested?([id]) } else { return false }
        case .copyImageText: if let id = currentID { model.onImageTextCopyRequested?(id) }
        case .commandPalette: model.onCommandsRequested?()
        case .tag: if flush() { model.onTagRequested?() }
        case .copy: copy()
        case .pin: pin()
        case .pinToFolder: if flush(), let id = currentID { model.onPinToFolderRequested?([id]) }
        case .nameAndPin: if flush(), let id = currentID { model.onNameAndPinRequested?(id) }
        case .pinnedOnly: guard flush() else { return true }; model.togglePinnedOnly()
        case .previous, .up, .next, .down, .first, .last, .previousPage, .nextPage: return performNavigation(action)
        case .open: link?.openCurrent()
        default: return false
        }
        return true
    }
}
