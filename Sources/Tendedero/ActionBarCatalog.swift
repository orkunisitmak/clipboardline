import AppKit
import Carbon

/// Semantic actions keep the palette independent of window focus and key-event
/// synthesis. The caller captures its origin and selection before showing it.
enum ActionBarAction: Equatable {
    case keyboard(KeyboardAction)
    case menu(ActionBarMenuAction)
    case openFolder(UUID), openTag(UUID), assignFolder(UUID), moveToFolder(UUID), unassignFolder(UUID), removeItemTag(UUID)

    var id: String {
        switch self {
        case let .keyboard(action): action.rawValue
        case let .menu(action): "menu." + action.rawValue
        case let .openFolder(id): "folder.open." + id.uuidString
        case let .openTag(id): "tag.open." + id.uuidString
        case let .assignFolder(id): "folder.assign." + id.uuidString
        case let .moveToFolder(id): "folder.move." + id.uuidString
        case let .unassignFolder(id): "folder.unassign." + id.uuidString
        case let .removeItemTag(id): "tag.unassign." + id.uuidString
        }
    }
}

enum ActionBarMenuAction: String, CaseIterable {
    case settings, settingsGeneral, settingsHistory, settingsSources, settingsCloud, settingsShortcuts, settingsAbout, clearUnsavedHistory
    case newNote, newFolder, newSubfolder, renameFolder, removeFolder, renameTag, removeTag, retain, restore, editDetails
    case scopeSaved, scopeFavorites, scopeUnorganized, scopeRecent, scopeTrash
    case grid, list, toggleSidebar, toggleInspector, toggleFullscreen, filters, clearFilters
    case sortNewest, sortOldest, sortTitle, sortTitleDescending, sortCopied, sortRelevance
    case searchAll, searchText, searchVisual, daysAny, days7, days30
    case refreshLink, openFile, quickLook, revealFile, saveToDesktop, takeDownLeft, takeDownRight, trimVideo, reuploadToR2
    case resetZoom, markupUndo, markupRedo, markupDelete, markupClear, markupSave, markupFinish, markupStyles
    case toggleLine, copyLatestImage, uploadLatestItem, openScreenshotsFolder, checkUpdates, installUpdate, upstreamReleases, quit
}

@MainActor enum ActionBarCatalog {
    enum Origin { case line, shelfPreview, library, libraryPreview, application }
    struct Context {
        var origin: Origin = .line
        var selectedCount = 0
        var kind: LibraryKind?
        var uploadedURL: String?
        var hasFile = false
        var isRecording = false
        var isDeleted = false
        var allPinned = false
        var hasItems = false
        var hasAnyItem = false
        var hasLatestImage = false
        var canUndoShelfRemoval = false
        var canUndoLibraryTrash = false
        var isMarkupEditing = false
        var annotationSelected = false
        var canUndoMarkup = false
        var canRedoMarkup = false
        var hasAnnotations = false
        var isTextEditing = false
        var inInbox = false
        var activeFavorites = false
        var lineRevealed = false
        var libraryAvailable = true
        var canCheckUpdates = false
        var canInstallUpdate = false
        var globalToggleHint = ""
        var copyLatestHint = ""
        var uploadLatestHint = ""
        var visibleShelves = Set<Shelf>()
        var libraryScope: LibraryQuery.Scope = .saved
        var collections = [LibraryCollection]()
        var tags = [LibraryTag]()
        var itemFolders = [LibraryCollection]()
        var itemTags = [LibraryTag]()
        var libraryKind: LibraryKind?
        var libraryListMode = false
        var libraryInspectorVisible = true
        var librarySidebarVisible = true
        var librarySort: LibraryQuery.Sort = .newest
        var librarySearchMode: LibraryQuery.SearchMode = .all
        var libraryDays: Int?
        var hasLibraryFilters = false
        var canTakeDownLeft = false
        var canTakeDownRight = false

        var isLibrary: Bool { origin == .library || origin == .libraryPreview }
        var isPreview: Bool { origin == .shelfPreview || origin == .libraryPreview }
        var hasSelection: Bool { selectedCount > 0 }
        var singleSelection: Bool { selectedCount == 1 }
        var isImage: Bool { singleSelection && kind == .image && hasFile && !isRecording && !isDeleted }
        var isText: Bool { singleSelection && kind == .text && !isDeleted }
        var isLink: Bool { singleSelection && kind == .link && !isDeleted }
    }
    struct Entry {
        let action: ActionBarAction
        let command: CommandPalette.Command
    }

    static func entries(context c: Context, bindings: KeyboardBindings) -> [Entry] {
        var result = [Entry]()
        // Frequently used operations lead the unfiltered list. Every other
        // browsing shortcut remains discoverable, including navigation.
        let leading: [KeyboardAction] = [.searchShelf, .library, .copy, .paste, .upload, .preview, .pin, .pinToFolder, .nameAndPin,
            .tag, .cropImage, .markupMarker, .markup, .editText, .copyImageText, .pinnedOnly]
        let keyboard = leading + KeyboardAction.allCases.filter { ![.commandPalette, .newNote, .newFolder].contains($0) && !leading.contains($0) }
        for action in keyboard {
            let availability = keyboardAvailability(action, c)
            let metadata = keyboardMetadata(action)
            let title = action == .searchShelf ? L("Search contents") : action == .search ? L("Search library") : action == .pin && c.allPinned ? L("Unpin") : action == .upload && c.uploadedURL != nil ? L("Copy public link") : action.title
            let semantic = ActionBarAction.keyboard(action)
            let scope = keyboardScope(action, c)
            result.append(Entry(action: semantic, command: .init(id: semantic.id, title: title,
                subtitle: scope == metadata.group ? "" : scope, keyHint: keyboardHint(action, c, bindings), systemImage: metadata.symbol,
                isEnabled: availability.0, group: metadata.group, keywords: metadata.keywords,
                disabledReason: availability.1, isActive: keyboardActive(action, c))))
        }
        for action in ActionBarMenuAction.allCases {
            let availability = menuAvailability(action, c)
            let metadata = menuMetadata(action)
            let semantic = ActionBarAction.menu(action)
            var title = metadata.title
            if action == .toggleLine { title = c.lineRevealed ? L("Hide line") : L("Show line") }
            if action == .toggleInspector { title = c.libraryInspectorVisible ? L("Hide details") : L("Show details") }
            result.append(Entry(action: semantic, command: .init(id: semantic.id, title: title,
                keyHint: action == .newNote ? bindings.title(.newNote, in: .library) : action == .newFolder ? bindings.title(.newFolder, in: .library) : menuHint(action, c), systemImage: metadata.symbol,
                isEnabled: availability.0, group: metadata.group, keywords: metadata.keywords,
                disabledReason: availability.1, isActive: menuActive(action, c))))
        }
        for folder in c.collections {
            let action = ActionBarAction.openFolder(folder.id)
            result.append(Entry(action: action, command: .init(id: action.id, title: L("Open folder") + ": " + folder.name,
                subtitle: L("Library"), systemImage: "folder", isEnabled: c.libraryAvailable,
                group: L("Folders"), keywords: ["folder", "klasör", "open", "aç"],
                disabledReason: c.libraryAvailable ? "" : L("Library unavailable"), isActive: c.libraryScope == .collection(folder.id))))
            let assign = ActionBarAction.assignFolder(folder.id)
            let canAssign = c.hasSelection && !c.isDeleted
            result.append(Entry(action: assign, command: .init(id: assign.id, title: L("Add to folder") + ": " + folder.name,
                subtitle: L("Selected item"), systemImage: "folder.badge.plus", isEnabled: canAssign,
                group: L("Organization"), keywords: ["add", "folder", "organize", "ekle", "klasör", "düzenle"],
                disabledReason: canAssign ? "" : L("Select an item first"))))
            let move = ActionBarAction.moveToFolder(folder.id)
            let canMove: Bool
            if case let .collection(source) = c.libraryScope { canMove = c.isLibrary && canAssign && source != folder.id }
            else { canMove = false }
            result.append(Entry(action: move, command: .init(id: move.id, title: L("Move to folder") + ": " + folder.name,
                subtitle: L("Selected item"), systemImage: "folder", isEnabled: canMove,
                group: L("Organization"), keywords: ["move", "folder", "taşı", "klasör"],
                disabledReason: canMove ? "" : L("Select items in a different folder first"))))
        }
        for tag in c.tags {
            let action = ActionBarAction.openTag(tag.id)
            result.append(Entry(action: action, command: .init(id: action.id, title: L("Tags") + ": #" + tag.name,
                subtitle: L("Library"), systemImage: "number", isEnabled: c.libraryAvailable,
                group: L("Tags"), keywords: ["tag", "etiket", "open", "aç"],
                disabledReason: c.libraryAvailable ? "" : L("Library unavailable"), isActive: c.libraryScope == .tag(tag.id))))
        }
        for folder in c.itemFolders {
            let action = ActionBarAction.unassignFolder(folder.id)
            let enabled = c.singleSelection && !c.isDeleted
            result.append(Entry(action: action, command: .init(id: action.id, title: L("Remove from folder") + ": " + folder.name,
                subtitle: L("Selected item"), systemImage: "folder.badge.minus", isEnabled: enabled,
                group: L("Organization"), keywords: ["remove", "folder", "klasörden", "çıkar"],
                disabledReason: enabled ? "" : L("Select one item first"))))
        }
        for tag in c.itemTags {
            let action = ActionBarAction.removeItemTag(tag.id)
            let enabled = c.singleSelection && !c.isDeleted
            result.append(Entry(action: action, command: .init(id: action.id, title: L("Remove tag") + ": #" + tag.name,
                subtitle: L("Selected item"), systemImage: "tag.slash", isEnabled: enabled,
                group: L("Organization"), keywords: ["remove", "tag", "etiket", "kaldır"],
                disabledReason: enabled ? "" : L("Select one item first"))))
        }
        return result
    }

    private static func keyboardAvailability(_ action: KeyboardAction, _ c: Context) -> (Bool, String) {
        let selected = c.hasSelection && !c.isDeleted
        let browsing = c.origin != .application
        func require(_ enabled: Bool, _ reason: String) -> (Bool, String) { (enabled, enabled ? "" : reason) }
        switch action {
        case .library, .search, .allTypes, .images, .texts, .links:
            return require(c.libraryAvailable, L("Library unavailable"))
        case .searchShelf, .toggleShelves, .toggleImages, .toggleTexts, .toggleLinks: return (true, "")
        case .copy, .paste, .preview, .pin, .pinToFolder, .nameAndPin, .tag:
            if action == .paste && c.isTextEditing { return (false, L("Finish editing first")) }
            return require(selected, L("Select an item first"))
        case .upload:
            if c.isTextEditing { return (false, L("Finish editing first")) }
            return require(c.singleSelection && !c.isDeleted, L("Select one item first"))
        case .open: return require(c.isLink, L("Select a link first"))
        case .cropImage, .markup, .markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText, .copyImageText:
            return require(c.isImage, L("Select one image first"))
        case .editText: return require(c.isText, L("Select a text item first"))
        case .finishEditing: return require(c.isTextEditing, L("Start editing text first"))
        case .pinnedOnly: return require(browsing, L("Open a shelf or Library first"))
        case .export: return require(c.hasSelection, L("Select an item first"))
        case .trash: return require(selected, L("Select an item first"))
        case .removeFromLine: return require(!c.isLibrary && selected, c.isLibrary ? L("Available on the shelves") : L("Select an item first"))
        case .undoRemoveFromLine: return require(!c.isLibrary && c.canUndoShelfRemoval, L("Nothing to undo"))
        case .undoTrash: return require(c.isLibrary && c.canUndoLibraryTrash, L("Nothing to undo"))
        case .focusNextPane, .focusPreviousPane: return require(c.origin == .library, L("Library unavailable"))
        case .newNote, .newFolder: return require(c.libraryAvailable, L("Library unavailable"))
        case .close: return require(browsing && (c.lineRevealed || c.isLibrary || c.isPreview), L("Open a shelf or Library first"))
        case .switchShelf: return require(c.origin == .line, L("Available on the shelves"))
        case .selectAll: return require(browsing && !c.isPreview && c.hasItems, c.isPreview ? L("Available on the shelves or in Library") : L("No items in this view"))
        case .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9:
            return require(c.origin == .line && c.hasItems, L("Available on the shelves"))
        case .first, .last, .previousPage, .nextPage:
            return require(browsing && c.hasItems, L("No items in this view"))
        case .extendPrevious, .extendNext, .extendUp, .extendDown:
            return require(browsing && !c.isPreview && c.hasItems, c.isPreview ? L("Available on the shelves or in Library") : L("No items in this view"))
        case .previous, .next, .up, .down: return require(browsing && c.hasItems, L("No items in this view"))
        case .commandPalette: return (false, "")
        }
    }

    private static func keyboardScope(_ action: KeyboardAction, _ c: Context) -> String {
        switch action {
        case .searchShelf: return c.isLibrary ? L("Search this view") + " · " + L("Library") : L("Search visible shelves: text, links and image OCR")
        case .search: return L("Search this view") + " · " + L("Library")
        case .library: return L("On the line")
        case .cropImage, .markup, .markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText: return L("Image markup")
        case .editText, .finishEditing: return L("Text preview")
        case .allTypes, .images, .texts, .links, .focusNextPane, .focusPreviousPane, .undoTrash, .newNote, .newFolder: return L("Library")
        case .first, .last, .previousPage, .nextPage: return c.isLibrary ? L("Library") : L("On the line")
        case .toggleShelves, .toggleImages, .toggleTexts, .toggleLinks, .switchShelf, .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9,
             .removeFromLine, .undoRemoveFromLine: return L("On the line")
        default: return c.selectedCount > 1 ? String(format: L("%d selected"), c.selectedCount) : c.isLibrary ? L("Library") : c.isPreview ? L("Preview") : L("On the line")
        }
    }

    private static func keyboardHint(_ action: KeyboardAction, _ c: Context, _ bindings: KeyboardBindings) -> String {
        let context = browsingContext(c)
        // These rows explicitly identify Library as their destination, even
        // when choosing one opens it from a shelf or preview.
        if action == .searchShelf, c.isLibrary { return bindings.title(.search, in: .library) }
        if [.search, .allTypes, .images, .texts, .links].contains(action) { return bindings.title(action, in: .library) }
        let tools: [KeyboardAction] = [.markupSelect, .markupPen, .markupMarker, .markupRectangle, .markupEllipse, .markupArrow, .markupLine, .markupText]
        if action == .cropImage {
            if c.origin == .library { return bindings.title(action, in: .library) }
            let hint = bindings.title(.cropImage, in: c.isMarkupEditing ? .imageMarkup : .imagePreview)
            return c.isPreview ? hint : sequence([context.map { bindings.title(.preview, in: $0) } ?? "", hint])
        }
        if action == .markup {
            if c.origin == .library { return bindings.title(action, in: .library) }
            let hint = bindings.title(.markup, in: c.isMarkupEditing ? .imageMarkup : .imagePreview)
            return c.isPreview ? hint : sequence([context.map { bindings.title(.preview, in: $0) } ?? "", hint])
        }
        if tools.contains(action) {
            let tool = bindings.title(action, in: .imageMarkup)
            if c.isMarkupEditing { return tool }
            let prefix = c.isPreview ? [] : [context.map { bindings.title(.preview, in: $0) } ?? ""]
            return sequence(prefix + [bindings.title(.markup, in: .imagePreview), tool])
        }
        if action == .editText && !c.isPreview {
            if c.origin == .library { return bindings.title(action, in: .library) }
            return sequence([context.map { bindings.title(.preview, in: $0) } ?? "", bindings.title(.editText, in: .textPreview)])
        }
        if action == .open && !c.isLibrary && !c.isPreview {
            return sequence([context.map { bindings.title(.preview, in: $0) } ?? "", bindings.title(.open, in: .linkPreview)])
        }
        // TextPreview checks Finish editing explicitly before normal browsing
        // dispatch; Command-Return consequently finishes instead of pasting.
        if action == .finishEditing { return c.isTextEditing ? bindings.title(action) : "" }
        guard let context else { return "" }
        var shortcuts = bindings.effectiveShortcuts(action, in: context)
        if c.isTextEditing {
            guard action == .pin || action == .pinnedOnly else { return "" }
            shortcuts.removeAll { $0.modifiers & (cmdKey | controlKey) == 0 }
        }
        if c.isMarkupEditing {
            let reserved = ([KeyboardAction.markup, .cropImage] + tools).flatMap { bindings.effectiveShortcuts($0, in: .imageMarkup) }
            shortcuts.removeAll { shortcut in
                let code = shortcut.keyCode, modifiers = shortcut.modifiers
                if code == 53 || (modifiers & cmdKey != 0 && [6, 36, 76].contains(code)) { return true }
                if modifiers == cmdKey && code == 1 { return true }
                if modifiers == 0 && [49, 51, 117].contains(code) { return true }
                return reserved.contains { $0.keyCode == code && $0.modifiers == modifiers }
            }
        }
        var seen = Set<String>()
        return shortcuts.map(\.title).filter { seen.insert($0).inserted }.joined(separator: " / ")
    }
    private static func browsingContext(_ c: Context) -> KeyboardContext? {
        switch c.origin {
        case .line: return .line
        case .library: return .library
        case .shelfPreview, .libraryPreview: return c.kind == .text ? .textPreview : c.kind == .link ? .linkPreview : .imagePreview
        // Settings and the status menu have no browsing surface. Their rows
        // teach the explicitly labeled "On the line" keys without enabling
        // selection-dependent commands or claiming those keys edit Settings.
        case .application: return .line
        }
    }
    private static func sequence(_ values: [String]) -> String {
        guard values.allSatisfy({ !$0.isEmpty }) else { return "" }
        return values.joined(separator: " → ")
    }

    private static func keyboardActive(_ action: KeyboardAction, _ c: Context) -> Bool {
        switch action {
        case .upload: c.singleSelection && c.uploadedURL != nil
        case .pin: c.allPinned && c.hasSelection
        case .pinnedOnly: c.activeFavorites
        case .toggleImages: c.visibleShelves.contains(.images)
        case .toggleTexts: c.visibleShelves.contains(.texts)
        case .toggleLinks: c.visibleShelves.contains(.links)
        case .markup: c.isMarkupEditing
        case .allTypes: c.isLibrary && c.libraryKind == nil
        case .images: c.isLibrary && c.libraryKind == .image
        case .texts: c.isLibrary && c.libraryKind == .text
        case .links: c.isLibrary && c.libraryKind == .link
        default: false
        }
    }

    private static func keyboardMetadata(_ action: KeyboardAction) -> (group: String, symbol: String, keywords: [String]) {
        let selection = L("Selected item"), navigation = L("Navigation and selection"), organization = L("Organization"), markup = L("Image markup")
        switch action {
        case .searchShelf: return (L("Search"), "magnifyingglass", ["search", "find", "ara", "arama", "OCR", "text", "link", "image", "görsel", "metin"])
        case .search: return (L("Search"), "magnifyingglass", ["search", "find", "library", "ara", "arama", "kütüphane"])
        case .library: return (L("Library"), "square.grid.2x2", ["library", "open", "kütüphane", "aç"])
        case .copy: return (selection, "doc.on.doc", ["copy", "clipboard", "kopyala", "pano"])
        case .paste: return (selection, "arrow.down.doc", ["paste", "previous app", "yapıştır", "uygulama"])
        case .upload: return (selection, "icloud.and.arrow.up", ["upload", "cloud", "r2", "cloudflare", "share", "public link", "url", "yükle", "bulut", "paylaş", "bağlantı"])
        case .preview: return (selection, "eye", ["preview", "space", "önizleme", "büyüt"])
        case .pin: return (organization, "pin", ["pin", "unpin", "favorite", "favourite", "sabitle", "favori", "kaldır"])
        case .pinToFolder: return (organization, "folder", ["pin", "folder", "sabitle", "klasör"])
        case .nameAndPin: return (organization, "pencil", ["name", "rename", "pin", "title", "isim", "ad", "sabitle", "başlık"])
        case .tag: return (organization, "tag", ["tag", "label", "etiket", "organize", "düzenle"])
        case .pinnedOnly: return (L("View"), "pin.fill", ["pinned", "favorite", "favourite", "filter", "sabitlenen", "favori", "filtre"])
        case .copyImageText: return (selection, "text.viewfinder", ["OCR", "image", "text", "copy", "görsel", "metin", "kopyala"])
        case .editText: return (selection, "square.and.pencil", ["text", "edit", "metin", "düzenle"])
        case .finishEditing: return (selection, "checkmark", ["text", "finish", "save", "metin", "tamamla", "kaydet", "bitti"])
        case .open: return (selection, "arrow.up.right.square", ["link", "open", "browser", "video", "bağlantı", "aç", "tarayıcı"])
        case .export: return (selection, "square.and.arrow.up", ["export", "save", "copies", "dışa aktar", "kaydet", "kopyalar"])
        case .trash: return (selection, "trash", ["delete", "trash", "sil", "çöp", "recoverable"])
        case .removeFromLine: return (selection, "minus.circle", ["remove", "delete", "take down", "sil", "askıdan", "indir"])
        case .undoRemoveFromLine: return (selection, "arrow.uturn.backward", ["undo", "restore", "backspace", "geri al", "silme"])
        case .undoTrash: return (L("Library"), "arrow.uturn.backward", ["undo", "trash", "backspace", "geri al", "çöp"])
        case .focusNextPane, .focusPreviousPane: return (navigation, "rectangle.split.3x1", ["focus", "pane", "keyboard", "tab", "odak", "bölme", "klavye"])
        case .newNote: return (L("Library"), "square.and.pencil", ["new", "note", "yeni", "not"])
        case .newFolder: return (L("Library"), "folder.badge.plus", ["new", "folder", "yeni", "klasör"])
        case .markup: return (markup, "pencil.tip.crop.circle", ["markup", "annotate", "draw", "edit image", "işaretle", "çiz", "görsel düzenle"])
        case .cropImage: return (markup, "crop", ["crop", "trim", "kırp", "kirp", "kes"])
        case .markupSelect: return (markup, "cursorarrow", ["select", "annotation", "seç", "işaretleme"])
        case .markupPen: return (markup, "pencil.tip", ["pen", "draw", "pencil", "kalem", "çiz"])
        case .markupMarker: return (markup, "highlighter", ["marker", "highlight", "highlighter", "işaretleyici", "vurgula", "fosforlu"])
        case .markupRectangle: return (markup, "rectangle", ["rectangle", "shape", "dikdörtgen", "şekil"])
        case .markupEllipse: return (markup, "circle", ["ellipse", "circle", "shape", "elips", "daire", "şekil"])
        case .markupArrow: return (markup, "arrow.up.right", ["arrow", "draw", "ok", "çiz"])
        case .markupLine: return (markup, "line.diagonal", ["line", "draw", "çizgi", "çiz"])
        case .markupText: return (markup, "textformat", ["text", "annotation", "add", "metin", "yazı", "ekle"])
        case .allTypes: return (L("Library views"), "square.grid.2x2", ["all", "types", "filter", "tümü", "tür", "filtre"])
        case .images: return (L("Library views"), "photo", ["images", "photos", "filter", "görsel", "fotoğraf", "filtre"])
        case .texts: return (L("Library views"), "text.alignleft", ["texts", "notes", "filter", "metin", "not", "filtre"])
        case .links: return (L("Library views"), "link", ["links", "URLs", "filter", "bağlantı", "filtre"])
        case .toggleImages: return (L("Shelves"), "photo", ["image", "photo", "shelf", "toggle", "görsel", "fotoğraf", "askı", "göster", "gizle"])
        case .toggleTexts: return (L("Shelves"), "text.alignleft", ["text", "shelf", "toggle", "metin", "askı", "göster", "gizle"])
        case .toggleLinks: return (L("Shelves"), "link", ["link", "shelf", "toggle", "bağlantı", "askı", "göster", "gizle"])
        case .toggleShelves: return (L("Shelves"), "rectangle.3.group", ["shelf", "toggle", "visible", "askı", "göster", "gizle"])
        case .switchShelf: return (L("Shelves"), "arrow.up.arrow.down", ["shelf", "switch", "tab", "askı", "değiştir", "geç"])
        case .close: return (L("View"), "xmark", ["close", "dismiss", "escape", "kapat", "çık"])
        case .previous: return (navigation, "arrow.left", ["navigate", "move", "previous", "left", "gez", "git", "önceki", "sol"])
        case .next: return (navigation, "arrow.right", ["navigate", "move", "next", "right", "gez", "git", "sonraki", "sağ"])
        case .first: return (navigation, "arrow.left.to.line", ["navigate", "first", "newest", "beginning", "git", "ilk", "en yeni", "baş"])
        case .last: return (navigation, "arrow.right.to.line", ["navigate", "last", "oldest", "end", "git", "son", "en eski"])
        case .previousPage: return (navigation, "chevron.left.2", ["previous", "page", "left", "önceki", "sayfa", "sol"])
        case .nextPage: return (navigation, "chevron.right.2", ["next", "page", "right", "sonraki", "sayfa", "sağ"])
        case .up: return (navigation, "arrow.up", ["navigate", "move", "up", "above", "shelf", "git", "yukarı", "üst", "askı"])
        case .down: return (navigation, "arrow.down", ["navigate", "move", "down", "below", "shelf", "git", "aşağı", "alt", "askı"])
        case .extendPrevious, .extendNext, .extendUp, .extendDown, .selectAll, .select1, .select2, .select3, .select4, .select5, .select6, .select7, .select8, .select9: return (navigation, "checkmark.circle", ["select", "selection", "all", "seç", "seçim", "tümü"])
        case .commandPalette: return (L("Application"), "command", [])
        }
    }

    private static func menuAvailability(_ action: ActionBarMenuAction, _ c: Context) -> (Bool, String) {
        func require(_ enabled: Bool, _ reason: String) -> (Bool, String) { (enabled, enabled ? "" : reason) }
        switch action {
        case .newNote, .newFolder, .scopeSaved, .scopeFavorites, .scopeUnorganized, .scopeRecent, .scopeTrash,
             .grid, .list, .toggleSidebar, .toggleInspector, .toggleFullscreen, .filters, .clearFilters,
             .sortNewest, .sortOldest, .sortTitle, .sortTitleDescending, .sortCopied, .sortRelevance,
             .searchAll, .searchText, .searchVisual, .daysAny, .days7, .days30:
            return require(c.libraryAvailable, L("Library unavailable"))
        case .newSubfolder:
            let isRootFolder: Bool
            if case let .collection(id) = c.libraryScope { isRootFolder = c.collections.contains { $0.id == id && $0.parentID == nil } } else { isRootFolder = false }
            return require(c.isLibrary && isRootFolder, L("Select a top-level folder first"))
        case .renameFolder, .removeFolder:
            if case .collection = c.libraryScope, c.isLibrary { return (true, "") }
            return (false, L("Select a folder first"))
        case .renameTag, .removeTag:
            if case .tag = c.libraryScope, c.isLibrary { return (true, "") }
            return (false, L("Select a tag first"))
        case .retain: return require(c.hasSelection && !c.isDeleted, L("Select an item first"))
        case .editDetails: return require(c.singleSelection && !c.isDeleted, L("Select one item first"))
        case .restore: return require(c.hasSelection && c.isDeleted, L("Select an item in Trash first"))
        case .refreshLink: return require(c.isLink, L("Select a link first"))
        case .openFile, .quickLook, .revealFile: return require(c.singleSelection && c.kind == .image && c.hasFile, L("Select one image first"))
        case .saveToDesktop: return require(!c.isLibrary && c.singleSelection && c.kind == .image && c.inInbox && !c.isDeleted, L("Select an image in the screenshots inbox first"))
        case .takeDownLeft: return require(!c.isLibrary && c.singleSelection && c.kind == .image && c.canTakeDownLeft, L("No items to the left"))
        case .takeDownRight: return require(!c.isLibrary && c.singleSelection && c.kind == .image && c.canTakeDownRight, L("No items to the right"))
        case .trimVideo: return require(c.singleSelection && c.kind == .image && c.hasFile && c.isRecording && !c.isDeleted, L("Select a video first"))
        case .reuploadToR2: return require(c.singleSelection && !c.isDeleted && c.uploadedURL != nil, L("Upload an item first"))
        case .resetZoom, .markupStyles: return require(c.isImage, L("Select one image first"))
        case .markupUndo: return require((c.isMarkupEditing || (c.isPreview && c.isImage)) && c.canUndoMarkup, L("Nothing to undo"))
        case .markupRedo: return require((c.isMarkupEditing || (c.isPreview && c.isImage)) && c.canRedoMarkup, L("Nothing to redo"))
        case .markupDelete: return require(c.isMarkupEditing && c.annotationSelected, L("Select an annotation first"))
        case .markupClear: return require(c.isMarkupEditing && c.hasAnnotations, L("No annotations to clear"))
        case .markupSave, .markupFinish: return require(c.isMarkupEditing, L("Start image markup first"))
        case .copyLatestImage: return require(c.hasLatestImage, L("No images on the line"))
        case .uploadLatestItem: return require(c.hasAnyItem, L("No items in this view"))
        case .checkUpdates: return require(c.canCheckUpdates, L("Update checks unavailable"))
        case .installUpdate: return require(c.canInstallUpdate, L("No update available"))
        case .clearUnsavedHistory: return require(c.libraryAvailable, L("Library unavailable"))
        case .settings, .settingsGeneral, .settingsHistory, .settingsSources, .settingsCloud, .settingsShortcuts, .settingsAbout,
             .toggleLine, .openScreenshotsFolder, .upstreamReleases, .quit: return (true, "")
        }
    }

    private static func menuHint(_ action: ActionBarMenuAction, _ c: Context) -> String {
        switch action {
        case .settings: return "⌘,"
        case .quit: return "⌘Q"
        case .toggleLine: return c.globalToggleHint
        case .copyLatestImage: return c.copyLatestHint
        case .uploadLatestItem: return c.uploadLatestHint
        case .markupUndo: return c.isMarkupEditing || (c.isPreview && c.canUndoMarkup) ? "⌘Z" : ""
        case .markupRedo: return c.isMarkupEditing || (c.isPreview && c.canRedoMarkup) ? "⇧⌘Z" : ""
        case .markupDelete: return c.isMarkupEditing ? "⌫ / ⌦" : ""
        case .markupSave: return c.isMarkupEditing ? "⌘S" : ""
        case .markupFinish: return c.isMarkupEditing ? "⌘↩ / Esc" : ""
        default: return ""
        }
    }

    private static func menuActive(_ action: ActionBarMenuAction, _ c: Context) -> Bool {
        guard c.isLibrary else { return false }
        switch action {
        case .scopeSaved: return c.libraryScope == .saved
        case .scopeFavorites: return c.libraryScope == .favorites
        case .scopeUnorganized: return c.libraryScope == .unorganized
        case .scopeRecent: return c.libraryScope == .recent
        case .scopeTrash: return c.libraryScope == .trash
        case .grid: return !c.libraryListMode
        case .list: return c.libraryListMode
        case .toggleSidebar: return c.librarySidebarVisible
        case .toggleInspector: return c.libraryInspectorVisible
        case .sortNewest: return c.librarySort == .newest
        case .sortOldest: return c.librarySort == .oldest
        case .sortTitle: return c.librarySort == .title
        case .sortTitleDescending: return c.librarySort == .titleDescending
        case .sortCopied: return c.librarySort == .copied
        case .sortRelevance: return c.librarySort == .relevance
        case .searchAll: return c.librarySearchMode == .all
        case .searchText: return c.librarySearchMode == .text
        case .searchVisual: return c.librarySearchMode == .visual
        case .daysAny: return c.libraryDays == nil
        case .days7: return c.libraryDays == 7
        case .days30: return c.libraryDays == 30
        default: return false
        }
    }

    private static func menuMetadata(_ action: ActionBarMenuAction) -> (title: String, group: String, symbol: String, keywords: [String]) {
        let app = L("Application"), library = L("Library"), views = L("Library views"), organization = L("Organization"), markup = L("Image markup")
        switch action {
        case .settings: return (L("Settings…"), app, "gearshape", ["settings", "preferences", "ayarlar", "tercihler"])
        case .settingsGeneral: return (L("General") + " · " + L("Settings"), app, "slider.horizontal.3", ["appearance", "theme", "color", "size", "language", "sounds", "login", "genel", "görünüm", "renk", "boyut", "dil", "ses", "açılış"])
        case .settingsHistory: return (L("History") + " · " + L("Settings"), app, "clock.arrow.circlepath", ["history", "retention", "days", "time", "geçmiş", "süre", "gün"])
        case .clearUnsavedHistory: return (L("Clear unsaved copies…"), app, "trash", ["history", "clear", "cleanup", "unsaved", "geçmiş", "temizle", "kaydedilmemiş"])
        case .settingsSources: return (L("Sources") + " · " + L("Settings"), app, "tray.and.arrow.down", ["sources", "capture", "clipboard", "screenshots", "watch folder", "kaynak", "yakala", "pano", "ekran görüntüsü", "izle"])
        case .settingsCloud: return (L("Cloud upload") + " · " + L("Settings"), app, "icloud.and.arrow.up", ["cloud", "upload", "r2", "cloudflare", "bucket", "bulut", "yükleme", "depolama"])
        case .settingsShortcuts: return (L("Keyboard shortcuts") + " · " + L("Settings"), app, "keyboard", ["keyboard", "shortcut", "keys", "remap", "accessibility", "klavye", "kısayol", "tuş", "erişilebilirlik"])
        case .settingsAbout: return (L("About") + " · " + L("Settings"), app, "info.circle", ["about", "version", "updates", "hakkında", "sürüm", "güncelleme"])
        case .newNote: return (L("New note"), library, "square.and.pencil", ["new", "note", "text", "yeni", "not", "metin"])
        case .newFolder: return (L("New folder"), organization, "folder.badge.plus", ["new", "create", "folder", "yeni", "oluştur", "klasör"])
        case .newSubfolder: return (L("New subfolder"), organization, "folder.badge.plus", ["new", "subfolder", "yeni", "alt klasör"])
        case .renameFolder: return (L("Rename folder"), organization, "pencil", ["rename", "folder", "isim", "ad", "klasör"])
        case .removeFolder: return (L("Remove folder"), organization, "folder.badge.minus", ["remove", "delete", "folder", "sil", "kaldır", "klasör"])
        case .renameTag: return (L("Rename tag"), organization, "pencil", ["rename", "tag", "isim", "ad", "etiket"])
        case .removeTag: return (L("Remove tag"), organization, "tag.slash", ["remove", "delete", "tag", "sil", "kaldır", "etiket"])
        case .retain: return (L("Save to library"), organization, "tray.and.arrow.down", ["save", "keep", "retain", "permanent", "kaydet", "sakla", "kalıcı"])
        case .restore: return (L("Restore"), organization, "arrow.uturn.backward", ["restore", "trash", "recover", "geri yükle", "kurtar", "çöp"])
        case .editDetails: return (L("Edit item details"), organization, "square.and.pencil", ["edit", "details", "title", "note", "name", "düzenle", "ayrıntı", "başlık", "not", "isim"])
        case .scopeSaved: return (L("My library"), views, "square.grid.2x2", ["saved", "library", "kaydedilen", "kütüphane"])
        case .scopeFavorites: return (L("Favorites"), views, "pin.fill", ["favorite", "favourite", "pinned", "favori", "sabitlenen"])
        case .scopeUnorganized: return (L("Unorganized"), views, "tray", ["unorganized", "inbox", "düzenlenmemiş", "gelen"])
        case .scopeRecent: return (L("Recent copies"), views, "clock", ["recent", "history", "copies", "son", "geçmiş", "kopyalar"])
        case .scopeTrash: return (L("Trash"), views, "trash", ["trash", "deleted", "recover", "çöp", "silinen", "kurtar"])
        case .grid: return (L("Grid"), views, "square.grid.2x2", ["grid", "cards", "ızgara", "kart"])
        case .list: return (L("List"), views, "list.bullet", ["list", "table", "liste", "tablo"])
        case .toggleSidebar: return (L("Toggle sidebar"), views, "sidebar.left", ["toggle", "sidebar", "yan çubuk", "göster", "gizle"])
        case .toggleInspector: return (L("Show details"), views, "sidebar.right", ["inspector", "details", "note", "title", "detay", "ayrıntı", "not", "başlık"])
        case .toggleFullscreen: return (L("Toggle full screen"), views, "arrow.up.left.and.arrow.down.right", ["fullscreen", "window", "tam ekran", "pencere"])
        case .filters: return (L("Filters"), views, "line.3.horizontal.decrease", ["filter", "domain", "tags", "date", "filtre", "alan adı", "etiket", "tarih"])
        case .clearFilters: return (L("Clear filters"), views, "line.3.horizontal.decrease.circle", ["clear", "reset", "filters", "temizle", "sıfırla", "filtre"])
        case .sortNewest: return (L("Newest first"), views, "arrow.down", ["sort", "newest", "date", "sırala", "en yeni", "tarih"])
        case .sortOldest: return (L("Oldest first"), views, "arrow.up", ["sort", "oldest", "date", "sırala", "en eski", "tarih"])
        case .sortTitle: return (L("Title"), views, "textformat.abc", ["sort", "title", "alphabet", "A Z", "sırala", "başlık", "alfabe"])
        case .sortTitleDescending: return (L("Title, Z–A"), views, "textformat.abc", ["sort", "title", "descending", "Z A", "sırala", "başlık", "azalan"])
        case .sortCopied: return (L("Last copied"), views, "doc.on.doc", ["sort", "copied", "last", "sırala", "kopyalanan", "son"])
        case .sortRelevance: return (L("Best match"), views, "sparkle.magnifyingglass", ["sort", "relevance", "match", "sırala", "alaka", "eşleşme"])
        case .searchAll: return (L("Text and visual content"), views, "text.viewfinder", ["search mode", "text", "visual", "arama türü", "metin", "görsel"])
        case .searchText: return (L("Text only (including OCR)"), views, "text.magnifyingglass", ["search mode", "text", "OCR", "arama türü", "metin"])
        case .searchVisual: return (L("Visual content only"), views, "photo", ["search mode", "visual", "image", "arama türü", "görsel"])
        case .daysAny: return (L("Any time"), views, "calendar", ["filter", "date", "any time", "filtre", "tarih", "tüm zamanlar"])
        case .days7: return (L("Last 7 days"), views, "calendar", ["filter", "date", "week", "filtre", "tarih", "hafta"])
        case .days30: return (L("Last 30 days"), views, "calendar", ["filter", "date", "month", "filtre", "tarih", "ay"])
        case .refreshLink: return (L("Refresh link preview"), L("Selected item"), "arrow.clockwise", ["refresh", "thumbnail", "link", "title", "yenile", "küçük resim", "bağlantı", "başlık"])
        case .openFile: return (L("Open file"), L("Selected item"), "arrow.up.right.square", ["open", "file", "image", "video", "aç", "dosya", "görsel"])
        case .quickLook: return (L("Quick Look"), L("Selected item"), "eye", ["quick look", "preview", "hızlı bakış", "önizleme"])
        case .revealFile: return (L("Show in Finder"), L("Selected item"), "folder", ["finder", "reveal", "file", "dosya", "göster"])
        case .saveToDesktop: return (L("Save to Desktop"), L("Selected item"), "desktopcomputer", ["save", "desktop", "kaydet", "masaüstü"])
        case .takeDownLeft: return (L("Take down everything to the left"), L("Selected item"), "arrow.left.to.line", ["remove", "left", "take down", "kaldır", "sol", "askıdan indir"])
        case .takeDownRight: return (L("Take down everything to the right"), L("Selected item"), "arrow.right.to.line", ["remove", "right", "take down", "kaldır", "sağ", "askıdan indir"])
        case .trimVideo: return (L("Trim video"), L("Selected item"), "scissors", ["trim", "video", "recording", "cut", "kırp", "kes", "kayıt"])
        case .reuploadToR2: return (L("Upload again to R2"), L("Selected item"), "arrow.clockwise.icloud", ["reupload", "upload again", "r2", "cloudflare", "new link", "tekrar yükle", "yeniden yükle", "yeni bağlantı"])
        case .resetZoom: return (L("Reset zoom"), markup, "arrow.counterclockwise", ["reset", "zoom", "fit", "sıfırla", "yakınlaştır", "sığdır"])
        case .markupUndo: return (L("Undo") + " · " + L("Image markup"), markup, "arrow.uturn.backward", ["undo", "markup", "annotation", "geri al", "işaretleme"])
        case .markupRedo: return (L("Redo") + " · " + L("Image markup"), markup, "arrow.uturn.forward", ["redo", "markup", "annotation", "yinele", "işaretleme"])
        case .markupDelete: return (L("Delete annotation"), markup, "trash", ["delete", "annotation", "sil", "işaretleme"])
        case .markupClear: return (L("Clear annotations"), markup, "eraser", ["clear", "all", "annotation", "temizle", "tümü", "işaretleme"])
        case .markupSave: return (L("Save") + " · " + L("Image markup"), markup, "square.and.arrow.down", ["save", "markup", "kaydet", "işaretleme"])
        case .markupFinish: return (L("Done") + " · " + L("Image markup"), markup, "checkmark", ["done", "finish", "markup", "bitti", "tamamla", "işaretleme"])
        case .markupStyles: return (L("Annotation style"), markup, "slider.horizontal.3", ["style", "color", "width", "fill", "font", "annotation", "stil", "renk", "kalınlık", "dolgu", "yazı", "işaretleme"])
        case .toggleLine: return (L("Show line"), app, "rectangle.3.group", ["show", "hide", "shelf", "line", "göster", "gizle", "askı"])
        case .copyLatestImage: return (L("Copy latest image"), app, "doc.on.doc", ["copy", "latest", "image", "kopyala", "son", "görsel"])
        case .uploadLatestItem: return (L("Upload latest item"), app, "icloud.and.arrow.up", ["upload", "latest", "newest", "r2", "cloudflare", "son öğe", "yükle", "bulut"])
        case .openScreenshotsFolder: return (L("Open screenshots folder"), app, "folder", ["screenshots", "folder", "open", "ekran görüntüsü", "klasör", "aç"])
        case .checkUpdates: return (L("Check for updates…"), app, "arrow.clockwise", ["check", "update", "release", "kontrol", "güncelleme", "sürüm"])
        case .installUpdate: return (L("Install update…"), app, "arrow.down.circle", ["install", "update", "download", "yükle", "güncelleme", "indir"])
        case .upstreamReleases: return (L("Check upstream releases…"), app, "arrow.up.right.square", ["upstream", "original", "release", "orijinal", "sürüm"])
        case .quit: return (String(format: L("Quit %@"), AppIdentity.name), app, "power", ["quit", "exit", "app", "çık", "kapat", "uygulama"])
        }
    }
}
