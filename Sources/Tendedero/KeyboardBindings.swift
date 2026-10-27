import AppKit
import Carbon

enum KeyboardContext: Hashable, CaseIterable { case line, library, imagePreview, textPreview, linkPreview, imageMarkup }
enum KeyboardAction: String, CaseIterable, Identifiable {
    case previous, next, first, last, previousPage, nextPage, up, down, extendPrevious, extendNext, extendUp, extendDown
    case copy, paste, selectAll, pin, pinnedOnly, preview, close, switchShelf, toggleShelves, export, trash
    case library, search, allTypes, images, texts, links, tag, open, editText, finishEditing
    case removeFromLine, undoRemoveFromLine, toggleLinks, toggleTexts, toggleImages, pinToFolder, searchShelf
    case copyImageText, commandPalette, nameAndPin, upload
    case focusNextPane, focusPreviousPane, undoTrash, newNote, newFolder
    case markup, cropImage, markupSelect, markupPen, markupMarker, markupRectangle, markupEllipse, markupArrow, markupLine, markupText
    case select1, select2, select3, select4, select5, select6, select7, select8, select9
    var id: Self { self }
    var settingsGroup: Int {
        switch self {
        case .previous, .next, .first, .last, .previousPage, .nextPage, .up, .down, .extendPrevious, .extendNext, .extendUp, .extendDown, .selectAll, .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9: 1
        case .toggleShelves, .toggleLinks, .toggleTexts, .toggleImages, .export, .trash, .search, .allTypes, .images, .texts, .links, .tag, .focusNextPane, .focusPreviousPane, .undoTrash, .newNote, .newFolder,
             .cropImage, .markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText: 2
        default: 0
        }
    }
    var scopeTitle: String {
        if contexts == [.imageMarkup] { return L("Image markup") }
        if self == .markup || self == .cropImage { return L("Image preview") }
        if contexts == [.line] { return L("On the line") }
        if contexts == [.library] { return L("Library") }
        if contexts == [.textPreview] { return L("Text preview") }
        if contexts == [.library, .linkPreview] { return L("Library") + " · " + L("Link preview") }
        if contexts == [.line, .imagePreview, .textPreview, .linkPreview] { return L("On the line") + " · " + L("Preview") }
        return L("On the line") + " · " + L("Library") + (contexts.contains(.imagePreview) ? " · " + L("Preview") : "")
    }
    var title: String {
        switch self {
        case .previous: L("Previous item"); case .next: L("Next item"); case .up: L("Move up"); case .down: L("Move down")
        case .first: L("First item"); case .last: L("Last item")
        case .previousPage: L("Previous shelf page"); case .nextPage: L("Next shelf page")
        case .extendPrevious: L("Select previous item"); case .extendNext: L("Select next item")
        case .extendUp: L("Extend selection up"); case .extendDown: L("Extend selection down")
        case .copy: L("Copy"); case .selectAll: L("Select all"); case .pin: L("Pin favorite"); case .pinnedOnly: L("Show pinned items")
        case .preview: L("Preview"); case .close: L("Close"); case .switchShelf: L("Switch shelf"); case .toggleShelves: L("Visible shelves")
        case .removeFromLine: L("Take down")
        case .searchShelf: L("Search shelves")
        case .undoRemoveFromLine: L("Undo take down")
        case .toggleLinks: L("Toggle link shelf"); case .toggleTexts: L("Toggle text shelf"); case .toggleImages: L("Toggle image shelf")
        case .pinToFolder: L("Pin to folder…")
        case .nameAndPin: L("Name and pin…")
        case .focusNextPane: L("Focus next pane")
        case .focusPreviousPane: L("Focus previous pane")
        case .undoTrash: L("Undo Move to Trash")
        case .newNote: L("New note")
        case .newFolder: L("New folder")
        case .export: L("Export copies…"); case .trash: L("Move to Trash…"); case .library: L("Open library")
        case .search: L("Search this view"); case .allTypes: L("All types"); case .images: L("Images"); case .texts: L("Texts"); case .links: L("Links")
        case .tag: L("Add tag…"); case .open: L("Open in browser"); case .editText: L("Edit text"); case .finishEditing: L("Finish editing")
        case .paste: L("Paste into previous app")
        case .upload: L("Upload to R2")
        case .copyImageText: L("Copy text from image")
        case .commandPalette: L("Actions")
        case .markup: L("Image markup")
        case .cropImage: L("Crop image")
        case .markupSelect: L("Select annotation")
        case .markupPen: L("Pen")
        case .markupMarker: L("Marker")
        case .markupRectangle: L("Rectangle")
        case .markupEllipse: L("Ellipse")
        case .markupArrow: L("Arrow")
        case .markupLine: L("Line")
        case .markupText: L("Text annotation")
        case .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9: String(format: L("Select item %d"), quickSelectionSlot! + 1)
        }
    }
    var contexts: Set<KeyboardContext> {
        switch self {
        case .markup, .cropImage: [.library, .imagePreview, .imageMarkup]
        case .markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText: [.imageMarkup]
        case .copy, .paste, .commandPalette: Set(KeyboardContext.allCases)
        case .library, .switchShelf, .toggleShelves, .toggleLinks, .toggleTexts, .toggleImages, .searchShelf: [.line]
        case .search, .allTypes, .images, .texts, .links: [.library]
        case .focusNextPane, .focusPreviousPane, .undoTrash, .newNote, .newFolder: [.library]
        case .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9: [.line]
        case .copyImageText: [.line, .library, .imagePreview]
        case .extendPrevious, .extendNext, .extendUp, .extendDown, .selectAll, .export, .trash: [.line, .library]
        case .open: [.library, .linkPreview]
        case .editText: [.library, .textPreview]
        case .finishEditing: [.textPreview]
        case .first, .last, .previousPage, .nextPage: [.line, .library, .imagePreview, .textPreview, .linkPreview]
        case .removeFromLine, .undoRemoveFromLine: [.line, .imagePreview, .textPreview, .linkPreview]
        default: Set(KeyboardContext.allCases).subtracting([.imageMarkup])
        }
    }
    var defaults: [KeyShortcut] {
        func key(_ code: Int, _ label: String, _ modifiers: Int = 0) -> KeyShortcut { KeyShortcut(keyCode: code, modifiers: modifiers, keyLabel: label) }
        return switch self {
        case .previous: [key(123,"←")]; case .next: [key(124,"→")]; case .up: [key(126,"↑")]; case .down: [key(125,"↓")]
        case .first: [key(123,"←",cmdKey)]; case .last: [key(124,"→",cmdKey)]
        case .previousPage: [key(123,"←",optionKey)]; case .nextPage: [key(124,"→",optionKey)]
        case .extendPrevious: [key(123,"←",shiftKey)]; case .extendNext: [key(124,"→",shiftKey)]
        case .extendUp: [key(126,"↑",shiftKey)]; case .extendDown: [key(125,"↓",shiftKey)]
        case .copy: [key(8,"C",cmdKey),key(36,"↩"),key(76,"↩")]
        case .selectAll: [key(0,"A",cmdKey)]
        case .pin: [key(35,"P"),key(35,"P",cmdKey)]
        case .pinnedOnly: [key(3,"F"),key(3,"F",cmdKey | shiftKey)]
        case .preview: [key(49,"Space")]; case .close: [key(53,"Esc")]
        case .switchShelf: [key(48,"Tab"),key(48,"Tab",shiftKey)]
        case .toggleShelves: [key(11,"B",cmdKey | shiftKey)]
        case .export: [key(14,"E",cmdKey | shiftKey)]; case .trash: [key(117,"⌦"),key(1,"S"),key(51,"⌫",cmdKey)]
        case .library: [key(37,"L")]; case .search: [key(3,"F",cmdKey)]
        case .removeFromLine: [key(1,"S")]
        case .searchShelf: [key(1,"S",shiftKey)]
        case .undoRemoveFromLine: [key(51,"⌫")]
        case .toggleLinks: [key(37,"L",shiftKey)]; case .toggleTexts: [key(17,"T",shiftKey)]; case .toggleImages: [key(34,"I",shiftKey)]
        case .pinToFolder: [key(35,"P",shiftKey)]
        case .nameAndPin: [key(35,"P",optionKey)]
        case .focusNextPane: [key(97,"F6"),key(48,"Tab",controlKey)]
        case .focusPreviousPane: [key(97,"F6",shiftKey),key(48,"Tab",controlKey | shiftKey)]
        case .undoTrash: [key(51,"⌫"),key(6,"Z",cmdKey)]
        case .newNote: [key(45,"N",cmdKey)]
        case .newFolder: [key(45,"N",cmdKey | shiftKey)]
        case .allTypes: [key(29,"0",cmdKey)]; case .images: [key(18,"1",cmdKey)]; case .texts: [key(19,"2",cmdKey)]; case .links: [key(20,"3",cmdKey)]
        case .tag: [key(17,"T",cmdKey | shiftKey)]
        case .open: [key(31,"O",cmdKey)]
        case .editText: [key(14,"E")]; case .finishEditing: [key(36,"↩",cmdKey),key(76,"↩",cmdKey)]
        case .paste: [key(36,"↩",cmdKey),key(76,"↩",cmdKey)]
        case .upload: [key(32,"U")]
        case .copyImageText: [key(8,"C",cmdKey | shiftKey)]
        case .commandPalette: [key(40,"K",cmdKey)]
        case .markup: [key(46,"M")]
        case .cropImage: [key(8,"C")]
        case .markupSelect: [key(9,"V")]
        case .markupPen: [key(11,"B")]
        case .markupMarker: [key(4,"H")]
        case .markupRectangle: [key(15,"R")]
        case .markupEllipse: [key(31,"O")]
        case .markupArrow: [key(0,"A")]
        case .markupLine: [key(2,"D")]
        case .markupText: [key(17,"T")]
        case .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9:
            [key([18,19,20,21,23,22,26,28,25][quickSelectionSlot!], String(quickSelectionSlot! + 1))]
        }
    }
    func defaults(in context: KeyboardContext) -> [KeyShortcut] {
        // Backspace undoes a shelf removal, including from its preview. Library
        // retains its existing Trash binding; forward Delete is unchanged.
        if self == .trash {
            if context == .library {
                return [KeyShortcut(keyCode: 1, modifiers: 0, keyLabel: "S"),
                    KeyShortcut(keyCode: 117, modifiers: 0, keyLabel: "⌦"),
                    KeyShortcut(keyCode: 51, modifiers: cmdKey, keyLabel: "⌫")]
            }
            return defaults.filter { $0.keyCode == 117 }
        }
        if self == .paste && context == .textPreview { return defaults }
        return defaults
    }
    var quickSelectionSlot: Int? { Self.quickSelectionActions.firstIndex(of: self) }
    static let quickSelectionActions: [Self] = [.select1,.select2,.select3,.select4,.select5,.select6,.select7,.select8,.select9]
}

/// Context keys never register a global hotkey and never capture typing in an
/// editor. Other instances read changes immediately from the same preferences.
@MainActor final class KeyboardBindings {
    private let defaults: UserDefaults
    private let key = "contextKeyboardBindingsV1"
    private var raw: Data?
    private var cached = [String: [KeyShortcut]]()
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func overrides() -> [String: [KeyShortcut]] {
        let data = defaults.data(forKey: key)
        if data != raw { raw = data; cached = data.flatMap { try? JSONDecoder().decode([String: [KeyShortcut]].self, from: $0) } ?? [:] }
        return cached
    }
    func shortcuts(_ action: KeyboardAction) -> [KeyShortcut] { overrides()[action.rawValue] ?? action.defaults }
    /// A command hint must describe the key that actually wins in its surface,
    /// including legacy overrides that intentionally shadow newer defaults.
    func effectiveShortcuts(_ action: KeyboardAction, in context: KeyboardContext) -> [KeyShortcut] {
        guard action.contexts.contains(context) else { return [] }
        let stored = overrides()
        return (stored[action.rawValue] ?? action.defaults(in: context)).filter {
            $0.isValidLocal && self.action(for: $0, in: context, stored: stored) == action
        }
    }
    func title(_ action: KeyboardAction, in context: KeyboardContext) -> String {
        shortcutTitle(effectiveShortcuts(action, in: context))
    }
    func title(_ action: KeyboardAction) -> String {
        shortcutTitle(shortcuts(action))
    }
    private func shortcutTitle(_ values: [KeyShortcut]) -> String {
        var seen = Set<String>()
        return values.map(\.title).filter { seen.insert($0).inserted }.joined(separator: " / ")
    }
    func hint(_ actions: [KeyboardAction]) -> String { actions.compactMap { action in shortcuts(action).first.map { $0.title + " " + action.title } }.joined(separator: " · ") }
    func matches(_ action: KeyboardAction, event: NSEvent) -> Bool {
        guard let value = KeyShortcut.capture(event, allowPlain: true) else { return false }
        return shortcuts(action).contains { $0.keyCode == value.keyCode && $0.modifiers == value.modifiers }
    }
    func action(for event: NSEvent, in context: KeyboardContext) -> KeyboardAction? {
        guard event.type == .keyDown, let value = KeyShortcut.capture(event, allowPlain: true) else { return nil }
        return action(for: value, in: context, stored: overrides())
    }
    private func action(for value: KeyShortcut, in context: KeyboardContext, stored: [String: [KeyShortcut]]) -> KeyboardAction? {
        func matches(_ action: KeyboardAction) -> Bool { action.contexts.contains(context) && (stored[action.rawValue] ?? action.defaults(in: context)).contains { $0.keyCode == value.keyCode && $0.modifiers == value.modifiers } }
        // Preserve a user's existing custom shortcut if a newly added default
        // uses its key. Explicit remapping still validates every shared context.
        return KeyboardAction.allCases.first { stored[$0.rawValue] != nil && matches($0) }
            ?? KeyboardAction.allCases.first(where: matches)
    }
    func set(_ shortcuts: [KeyShortcut], for action: KeyboardAction) throws {
        try validate(shortcuts, for: action)
        var values = overrides(); values[action.rawValue] = shortcuts
        defaults.set(try JSONEncoder().encode(values), forKey: key); raw = nil
    }
    private func validate(_ shortcuts: [KeyShortcut], for action: KeyboardAction, restoringDefaults: Bool = false) throws {
        guard shortcuts.allSatisfy(\.isValidLocal) else { throw HistoryFiles.Failure.invalidDestination }
        let stored = overrides()
        for context in action.contexts {
            let candidates = restoringDefaults ? action.defaults(in: context) : shortcuts
            for other in KeyboardAction.allCases where other != action && other.contexts.contains(context) {
                // In the text editor Command-Enter finishes editing; outside
                // editing the same key pastes the browsed item to its target.
                if context == .textPreview && Set([action, other]) == Set([.paste, .finishEditing]) { continue }
                let values = stored[other.rawValue] ?? other.defaults(in: context)
                if candidates.contains(where: { candidate in values.contains { $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers } }) {
                    throw Conflict(action: other)
                }
            }
        }
    }
    func reset(_ action: KeyboardAction? = nil) throws {
        if let action { try validate(action.defaults, for: action, restoringDefaults: true); var values = overrides(); values.removeValue(forKey: action.rawValue); defaults.set(try JSONEncoder().encode(values), forKey: key) }
        else { defaults.removeObject(forKey: key) }
        raw = nil; cached.removeAll()
    }
    struct Conflict: LocalizedError {
        let action: KeyboardAction
        var errorDescription: String? { String(format: L("This shortcut is already used for %@"), action.title) }
    }
}
