import AppKit
import Carbon

struct KeyShortcut: Codable, Equatable {
    let keyCode: Int
    let modifiers: Int
    let keyLabel: String

    var isValid: Bool {
        let allowed = controlKey | optionKey | shiftKey | cmdKey
        return (0..<128).contains(keyCode) && modifiers & (controlKey | cmdKey) != 0
            && modifiers & ~allowed == 0 && !keyLabel.isEmpty
    }
    var isValidLocal: Bool { (0..<128).contains(keyCode) && modifiers & ~(controlKey | optionKey | shiftKey | cmdKey) == 0 && !keyLabel.isEmpty }
    var title: String {
        (modifiers & controlKey != 0 ? "⌃" : "") + (modifiers & optionKey != 0 ? "⌥" : "")
        + (modifiers & shiftKey != 0 ? "⇧" : "") + (modifiers & cmdKey != 0 ? "⌘" : "") + keyLabel
    }
    static let presets = [
        KeyShortcut(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey, keyLabel: "C"),
        KeyShortcut(keyCode: kVK_ANSI_C, modifiers: controlKey | shiftKey, keyLabel: "C")
    ]
    static func capture(_ event: NSEvent, allowPlain: Bool = false) -> KeyShortcut? {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        let labels: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 76: "↩", 49: "Space", 51: "⌫", 117: "⌦", 53: "Esc", 48: "Tab", 115: "Home", 119: "End", 116: "Page ↑", 121: "Page ↓", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = KeyShortcut(keyCode: Int(event.keyCode), modifiers: modifiers, keyLabel: label)
        return (allowPlain ? shortcut.isValidLocal : shortcut.isValid) ? shortcut : nil
    }
}

/// Only the explicitly focused line panel calls this controller.
@MainActor
final class LineKeyboard {
    let line: Line
    let onCopy: (UUID) -> Void
    let onPreview: (UUID) -> Void
    let onClose: () -> Void
    let onTextCopy: (UUID) -> Void
    let onTextPreview: (UUID) -> Void
    let onLinkPreview: (UUID) -> Void
    let onCopyAndClose: (() -> Void)?

    init(line: Line, onCopy: @escaping (UUID) -> Void, onPreview: @escaping (UUID) -> Void,
         onClose: @escaping () -> Void, onTextCopy: @escaping (UUID) -> Void = { _ in },
         onTextPreview: @escaping (UUID) -> Void = { _ in }, onLinkPreview: @escaping (UUID) -> Void = { _ in },
         onCopyAndClose: (() -> Void)? = nil) {
        self.line = line; self.onCopy = onCopy; self.onPreview = onPreview; self.onClose = onClose
        self.onTextCopy = onTextCopy; self.onTextPreview = onTextPreview
        self.onLinkPreview = onLinkPreview
        self.onCopyAndClose = onCopyAndClose
    }
    func handle(_ event: NSEvent) -> Bool {
        guard let action = line.keyboardBindings.action(for: event, in: .line) else { return false }
        guard line.searchEditingShelf == nil || (action == .commandPalette && !event.modifierFlags.intersection([.command, .control]).isEmpty) else { return false }
        return perform(action, event: event)
    }
    /// Shared by keyboard input and the action bar. Keep the native event for
    /// Return's focused-item copy; a chosen Copy command copies the selection.
    @discardableResult func perform(_ action: KeyboardAction, event: NSEvent? = nil) -> Bool {
        switch action {
        case .paste: line.onPasteRequested?(line.activeActionIDs)
        case .upload: if line.activeActionIDs.count == 1, let id = line.activeActionIDs.first { line.upload(id) }
        case .tag: if !line.activeActionIDs.isEmpty { line.onTagRequested?(line.activeActionIDs) }
        case .copyImageText: if line.activeShelf == .images, let id = line.focusedID { line.onImageTextCopyRequested?(id) }
        case .commandPalette: line.onCommandsRequested?()
        case .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9: line.selectQuickSlot(action.quickSelectionSlot!)
        case .searchShelf: line.beginShelfSearch()
        case .library: line.onLibraryRequested?()
        case .switchShelf: line.switchShelf()
        case .selectAll: line.selectAllActive()
        case .pin: line.pinActiveSelection()
        case .pinToFolder: if !line.activeIDs.isEmpty { line.onPinToFolderRequested?(Array(line.activeIDs)) }
        case .nameAndPin:
            // Snapshot visible order before names or pins can change filtering.
            let ids = line.activeActionIDs
            if !ids.isEmpty { line.onNameAndPinBatchRequested?(ids) }
        case .pinnedOnly: line.setActiveFavorites(!line.activeFavoritesOnly)
        case .toggleShelves: line.toggleBothShelves()
        case .export: line.onExportRequested?()
        case .trash: line.onTrashRequested?()
        case .removeFromLine: line.removeActiveSelectionFromShelf()
        case .undoRemoveFromLine: line.undoShelfRemoval()
        case .toggleLinks, .toggleTexts, .toggleImages:
            let shelf: Shelf = action == .toggleLinks ? .links : action == .toggleTexts ? .texts : .images
            if !line.toggleShelf(shelf) { onClose() }
        case .copy:
            if let event, (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if let onCopyAndClose { onCopyAndClose() }
                else if line.activeShelf == .links { line.links.copySelection() }
                else if line.activeShelf == .texts { if let id = line.texts.focusedID { onTextCopy(id) } }
                else if let id = line.focusedID { onCopy(id) }
            } else { line.copySelection() }
        case .preview:
            if line.activeShelf == .links { if let id = line.links.focusedID { onLinkPreview(id) } }
            else if line.activeShelf == .texts { if let id = line.texts.focusedID { onTextPreview(id) } }
            else if let id = line.focusedID { onPreview(id) }
        case .close:
            if line.closeShelfSearch() { return true }
            if line.activeShelf == .links { line.links.cancelSelection() }
            else if line.activeShelf == .texts { line.texts.cancelSelection() }
            else { line.cancelSelection() }; onClose()
        case .first, .last: line.moveToShelfBoundary(last: action == .last)
        case .previousPage, .nextPage: line.moveShelfPage(action == .previousPage ? -1 : 1)
        case .up, .down: line.moveSelectionShelf(action == .up ? -1 : 1)
        case .previous, .next, .extendPrevious, .extendUp, .extendNext, .extendDown:
            let delta = [.previous, .extendPrevious, .extendUp].contains(action) ? -1 : 1
            let extending = [.extendPrevious, .extendUp, .extendNext, .extendDown].contains(action)
            if line.activeShelf == .links { line.links.moveSelection(delta, width: line.viewportWidth, extending: extending) }
            else if line.activeShelf == .texts { line.texts.moveSelection(delta, width: line.viewportWidth, extending: extending) }
            else { line.moveSelection(delta, extending: extending) }
        default: return false
        }
        return true
    }
}
