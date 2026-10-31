import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ActionBarCatalogTests: HistoryTestCase {
    private func command(_ action: ActionBarAction, context: ActionBarCatalog.Context, bindings: KeyboardBindings) throws -> CommandPalette.Command {
        try XCTUnwrap(ActionBarCatalog.entries(context: context, bindings: bindings).first { $0.action == action }?.command)
    }

    func testCatalogCoversEveryBrowsingShortcutAndMenuWithoutDuplicateIDs() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        let folder = LibraryCollection(id: UUID(), name: "Project", parentID: nil)
        let tag = LibraryTag(id: UUID(), name: "Research")
        context.collections = [folder]; context.tags = [tag]
        context.itemFolders = [folder]; context.itemTags = [tag]
        let entries = ActionBarCatalog.entries(context: context, bindings: bindings)
        let keyboard = entries.compactMap { entry -> KeyboardAction? in if case let .keyboard(action) = entry.action { return action }; return nil }
        let menu = entries.compactMap { entry -> ActionBarMenuAction? in if case let .menu(action) = entry.action { return action }; return nil }
        XCTAssertEqual(Set(keyboard), Set(KeyboardAction.allCases.filter { ![.commandPalette, .newNote, .newFolder].contains($0) }))
        XCTAssertEqual(try command(.menu(.newNote), context: context, bindings: bindings).keyHint, bindings.title(.newNote, in: .library))
        XCTAssertEqual(try command(.menu(.newFolder), context: context, bindings: bindings).keyHint, bindings.title(.newFolder, in: .library))
        XCTAssertEqual(Set(menu), Set(ActionBarMenuAction.allCases))
        XCTAssertEqual(entries.count, Set(entries.map { $0.command.id }).count)
        XCTAssertTrue(entries.allSatisfy { !$0.command.title.isEmpty && !$0.command.group.isEmpty && !$0.command.systemImage.isEmpty })
        XCTAssertTrue(entries.allSatisfy { $0.command.id == $0.action.id })
        XCTAssertTrue(entries.allSatisfy { $0.command.isEnabled || !$0.command.disabledReason.isEmpty })
        XCTAssertEqual(entries.first?.action, .keyboard(.searchShelf))
    }

    func testCatalogEnablesDirectImageToolsAndTextEditingForCorrectSelectedKind() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .image; context.hasFile = true
        for action in [KeyboardAction.markup, .markupMarker, .markupText, .copyImageText] {
            XCTAssertTrue(try command(.keyboard(action), context: context, bindings: bindings).isEnabled)
        }
        XCTAssertFalse(try command(.keyboard(.editText), context: context, bindings: bindings).isEnabled)
        context.isRecording = true
        XCTAssertFalse(try command(.keyboard(.markupMarker), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.menu(.trimVideo), context: context, bindings: bindings).isEnabled)
        context.isRecording = false; context.hasFile = false; context.kind = .text
        XCTAssertTrue(try command(.keyboard(.editText), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.keyboard(.copyImageText), context: context, bindings: bindings).isEnabled)
        context.selectedCount = 2
        XCTAssertFalse(try command(.keyboard(.editText), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.keyboard(.pin), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.keyboard(.nameAndPin), context: context, bindings: bindings).isEnabled)
        context.kind = .link; context.selectedCount = 1
        XCTAssertTrue(try command(.keyboard(.open), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.menu(.refreshLink), context: context, bindings: bindings).isEnabled)
    }

    func testCatalogReflectsRemappedDisabledAndContextSpecificShortcutHints() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .image; context.hasFile = true
        try bindings.set([KeyShortcut(keyCode: 35, modifiers: controlKey | optionKey, keyLabel: "P")], for: .pin)
        XCTAssertEqual(try command(.keyboard(.pin), context: context, bindings: bindings).keyHint, "⌃⌥P")
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "Space → M → H")
        XCTAssertEqual(try command(.keyboard(.markup), context: context, bindings: bindings).keyHint, "Space → M")
        XCTAssertEqual(try command(.keyboard(.trash), context: context, bindings: bindings).keyHint, "⌦")
        context.origin = .library
        XCTAssertEqual(try command(.keyboard(.trash), context: context, bindings: bindings).keyHint, "S / ⌦ / ⌘⌫")
        XCTAssertEqual(try command(.keyboard(.undoTrash), context: context, bindings: bindings).keyHint, "⌫ / ⌘Z")
        XCTAssertEqual(try command(.keyboard(.searchShelf), context: context, bindings: bindings).keyHint, bindings.title(.search))
        context.origin = .libraryPreview
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "M → H")
        context.isMarkupEditing = true
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "H")
        try bindings.set([], for: .markupMarker)
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "")
        context.isMarkupEditing = false
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "", "A disabled tool shortcut must not imply M alone activates that tool")
    }

    func testCatalogKeepsNativeMarkupShortcutHintsAndAvailabilityInMarkupContext() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.origin = .shelfPreview; context.selectedCount = 1; context.kind = .image; context.hasFile = true
        let actions: [ActionBarMenuAction] = [.markupUndo, .markupRedo, .markupDelete, .markupClear, .markupSave, .markupFinish]
        for action in actions {
            let item = try command(.menu(action), context: context, bindings: bindings)
            XCTAssertFalse(item.isEnabled); XCTAssertEqual(item.keyHint, "")
        }
        context.isMarkupEditing = true; context.canUndoMarkup = true; context.canRedoMarkup = true
        context.annotationSelected = true; context.hasAnnotations = true
        for action in actions { XCTAssertTrue(try command(.menu(action), context: context, bindings: bindings).isEnabled) }
        XCTAssertEqual(try command(.menu(.markupUndo), context: context, bindings: bindings).keyHint, "⌘Z")
        XCTAssertEqual(try command(.menu(.markupRedo), context: context, bindings: bindings).keyHint, "⇧⌘Z")
        XCTAssertEqual(try command(.menu(.markupFinish), context: context, bindings: bindings).keyHint, "⌘↩ / Esc")
    }

    func testCatalogShelfLibraryTrashAndUpdateAvailabilityDoNotBleedAcrossContexts() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .text; context.hasItems = true
        context.canUndoShelfRemoval = true; context.visibleShelves = [.images, .texts]
        XCTAssertTrue(try command(.keyboard(.removeFromLine), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.keyboard(.undoRemoveFromLine), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.keyboard(.switchShelf), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.copyLatestImage), context: context, bindings: bindings).isEnabled, "Text results do not imply an image exists")
        context.hasLatestImage = true
        XCTAssertTrue(try command(.menu(.copyLatestImage), context: context, bindings: bindings).isEnabled)
        context.origin = .library
        for action in [KeyboardAction.removeFromLine, .undoRemoveFromLine, .switchShelf, .select1] {
            XCTAssertFalse(try command(.keyboard(action), context: context, bindings: bindings).isEnabled)
        }
        XCTAssertTrue(try command(.keyboard(.nextPage), context: context, bindings: bindings).isEnabled)
        context.canUndoLibraryTrash = true
        XCTAssertTrue(try command(.keyboard(.undoTrash), context: context, bindings: bindings).isEnabled)
        context.libraryScope = .trash; context.isDeleted = true
        XCTAssertTrue(try command(.menu(.restore), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.retain), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.keyboard(.trash), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.checkUpdates), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.installUpdate), context: context, bindings: bindings).isEnabled)
        context.canCheckUpdates = true; context.canInstallUpdate = true
        XCTAssertTrue(try command(.menu(.checkUpdates), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.menu(.installUpdate), context: context, bindings: bindings).isEnabled)
        context.libraryAvailable = false
        XCTAssertFalse(try command(.keyboard(.library), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.newNote), context: context, bindings: bindings).isEnabled)
    }

    func testCopyStaysAvailableForTrashedItemsWhileEditingActionsDoNot() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.origin = .library; context.libraryScope = .trash; context.isDeleted = true
        context.selectedCount = 1; context.kind = .text; context.hasItems = true
        let copy = try command(.keyboard(.copy), context: context, bindings: bindings)
        XCTAssertTrue(copy.isEnabled); XCTAssertEqual(copy.disabledReason, "")
        for action in [KeyboardAction.paste, .preview, .pin, .tag] {
            XCTAssertFalse(try command(.keyboard(action), context: context, bindings: bindings).isEnabled)
        }
        context.selectedCount = 0
        XCTAssertFalse(try command(.keyboard(.copy), context: context, bindings: bindings).isEnabled)
    }

    func testCatalogFolderTagCommandsUseStableIDsAndCurrentScope() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        let folder = LibraryCollection(id: UUID(), name: "Project", parentID: nil)
        let child = LibraryCollection(id: UUID(), name: "Drafts", parentID: folder.id)
        let tag = LibraryTag(id: UUID(), name: "Research")
        var context = ActionBarCatalog.Context()
        context.origin = .library; context.selectedCount = 1; context.kind = .text
        context.collections = [folder, child]; context.tags = [tag]
        context.itemFolders = [folder]; context.itemTags = [tag]
        context.libraryScope = .collection(folder.id)
        XCTAssertTrue(try command(.menu(.newSubfolder), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.menu(.renameFolder), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.menu(.renameTag), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.openFolder(folder.id), context: context, bindings: bindings).isActive)
        XCTAssertTrue(try command(.unassignFolder(folder.id), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.removeItemTag(tag.id), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.assignFolder(child.id), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.moveToFolder(child.id), context: context, bindings: bindings).isEnabled)
        XCTAssertFalse(try command(.moveToFolder(folder.id), context: context, bindings: bindings).isEnabled)
        let originalID = try command(.openFolder(folder.id), context: context, bindings: bindings).id
        context.collections[0].name = "Renamed project"
        XCTAssertEqual(try command(.openFolder(folder.id), context: context, bindings: bindings).id, originalID)
        context.libraryScope = .collection(child.id)
        XCTAssertFalse(try command(.menu(.newSubfolder), context: context, bindings: bindings).isEnabled)
        context.libraryScope = .tag(tag.id)
        XCTAssertFalse(try command(.moveToFolder(child.id), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.menu(.renameTag), context: context, bindings: bindings).isEnabled)
        XCTAssertTrue(try command(.openTag(tag.id), context: context, bindings: bindings).isActive)
        context.selectedCount = 2
        XCTAssertFalse(try command(.unassignFolder(folder.id), context: context, bindings: bindings).isEnabled)
    }

    func testCatalogBilingualKeywordsAreExplicitAndNeverIncludeOpaqueIdentifiers() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .image; context.hasFile = true
        let opaqueFolderID = UUID()
        context.collections = [LibraryCollection(id: opaqueFolderID, name: "Project", parentID: nil)]
        let entries = ActionBarCatalog.entries(context: context, bindings: bindings)
        let palette = CommandPalette(commands: entries.map(\.command), onExecute: { _ in })
        defer { palette.onClose = nil; palette.window.close(); palette.window.contentView = nil }
        palette.updateQuery("işaretleyici")
        XCTAssertEqual(palette.visibleCommands.map(\.id), [ActionBarAction.keyboard(.markupMarker).id])
        palette.updateQuery("sabitle")
        XCTAssertTrue(palette.visibleCommands.contains { $0.id == ActionBarAction.keyboard(.pin).id })
        palette.updateQuery("keyboard remap")
        XCTAssertEqual(palette.visibleCommands.map(\.id), [ActionBarAction.menu(.settingsShortcuts).id])
        palette.updateQuery(opaqueFolderID.uuidString)
        XCTAssertTrue(palette.visibleCommands.isEmpty)
        palette.updateQuery("menu.settingsHistory")
        XCTAssertTrue(palette.visibleCommands.isEmpty)
        palette.updateQuery("Project")
        XCTAssertEqual(Set(palette.visibleCommands.map(\.id)), Set([ActionBarAction.openFolder(opaqueFolderID).id,
            ActionBarAction.assignFolder(opaqueFolderID).id, ActionBarAction.moveToFolder(opaqueFolderID).id]))
    }

    func testCatalogActiveStatesFollowCurrentShelfAndLibraryFilters() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 2; context.allPinned = true; context.visibleShelves = [.texts, .links]
        context.activeFavorites = true
        XCTAssertTrue(try command(.keyboard(.pin), context: context, bindings: bindings).isActive)
        XCTAssertTrue(try command(.keyboard(.pinnedOnly), context: context, bindings: bindings).isActive)
        XCTAssertFalse(try command(.keyboard(.toggleImages), context: context, bindings: bindings).isActive)
        XCTAssertTrue(try command(.keyboard(.toggleTexts), context: context, bindings: bindings).isActive)
        context.origin = .library; context.libraryListMode = true; context.libraryKind = .link
        context.librarySort = .titleDescending; context.librarySearchMode = .visual; context.libraryDays = 7
        for action in [ActionBarMenuAction.list, .sortTitleDescending, .searchVisual, .days7] {
            XCTAssertTrue(try command(.menu(action), context: context, bindings: bindings).isActive)
        }
        for action in [ActionBarMenuAction.grid, .sortNewest, .searchAll, .daysAny] {
            XCTAssertFalse(try command(.menu(action), context: context, bindings: bindings).isActive)
        }
        XCTAssertTrue(try command(.keyboard(.links), context: context, bindings: bindings).isActive)
        context.origin = .line
        XCTAssertFalse(try command(.menu(.list), context: context, bindings: bindings).isActive, "Remembered Library state must not look like the current shelf view")
    }

    func testEffectiveShortcutHintsHonorContextDefaultsExplicitOverridesAndLegacyPrecedence() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        XCTAssertEqual(bindings.effectiveShortcuts(.trash, in: .line).map(\.keyCode), [117])
        XCTAssertEqual(bindings.effectiveShortcuts(.trash, in: .library).map(\.keyCode), [1, 117, 51])
        XCTAssertTrue(bindings.effectiveShortcuts(.trash, in: .imagePreview).isEmpty)
        try bindings.set([], for: .undoRemoveFromLine)
        try bindings.set([], for: .undoTrash)
        try bindings.set([KeyShortcut(keyCode: 51, modifiers: 0, keyLabel: "⌫")], for: .trash)
        var context = ActionBarCatalog.Context()
        context.origin = .line; context.selectedCount = 1; context.kind = .text
        XCTAssertEqual(bindings.title(.trash, in: .line), "⌫", "An explicit mapping is not filtered using the default Backspace policy")
        XCTAssertEqual(try command(.keyboard(.trash), context: context, bindings: bindings).keyHint, "⌫")
        // Prior releases may already have a user override on a newer default.
        // Hints must show only the bindings the same resolver will execute.
        let legacy = ["next": [KeyShortcut(keyCode: 35, modifiers: 0, keyLabel: "P")]]
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "contextKeyboardBindingsV1")
        XCTAssertEqual(bindings.title(.next, in: .line), "P")
        XCTAssertEqual(bindings.title(.pin, in: .line), "⌘P", "An explicit legacy Next wins over the newer plain-P pin default")
        XCTAssertEqual(try command(.keyboard(.pin), context: context, bindings: bindings).keyHint, "⌘P")
        // The action bar also opens during markup. Remapping it must not
        // silently steal the marker's H key from that active canvas.
        let markerKey = KeyShortcut(keyCode: 4, modifiers: 0, keyLabel: "H")
        XCTAssertThrowsError(try bindings.set([markerKey], for: .commandPalette))
        try bindings.set([], for: .markupMarker)
        try bindings.set([markerKey], for: .commandPalette)
        XCTAssertEqual(bindings.title(.commandPalette, in: .imageMarkup), "H")
        XCTAssertTrue(bindings.title(.markupMarker, in: .imageMarkup).isEmpty)
    }

    func testCatalogOmitsNonNativePreviewKeysAndAllowsNativeSingleShelfSwitching() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .text; context.hasItems = true; context.visibleShelves = [.texts]
        XCTAssertTrue(try command(.keyboard(.switchShelf), context: context, bindings: bindings).isEnabled,
            "Tab cycles all shelf types when only one is visible")
        for origin in [ActionBarCatalog.Origin.shelfPreview, .libraryPreview] {
            context.origin = origin
            for action in [KeyboardAction.trash, .export, .selectAll] {
                XCTAssertEqual(try command(.keyboard(action), context: context, bindings: bindings).keyHint, "",
                    "An explicit preview command must not claim a key handled only by its underlying browsing surface")
            }
            XCTAssertFalse(try command(.keyboard(.switchShelf), context: context, bindings: bindings).isEnabled)
        }
        context.isTextEditing = true
        XCTAssertEqual(try command(.keyboard(.pin), context: context, bindings: bindings).keyHint, "⌘P", "Plain P types in the editor")
        XCTAssertEqual(try command(.keyboard(.copy), context: context, bindings: bindings).keyHint, "", "Native copy in the editor copies its text selection, not necessarily the full saved item")
        XCTAssertEqual(try command(.keyboard(.paste), context: context, bindings: bindings).keyHint, "")
        XCTAssertEqual(try command(.keyboard(.finishEditing), context: context, bindings: bindings).keyHint, "⌘↩")
        context.kind = .image; context.hasFile = true; context.isTextEditing = false; context.isMarkupEditing = true
        XCTAssertEqual(try command(.keyboard(.paste), context: context, bindings: bindings).keyHint, "", "Command-Return finishes markup")
        XCTAssertEqual(try command(.keyboard(.preview), context: context, bindings: bindings).keyHint, "", "Space pans in markup")
        XCTAssertEqual(try command(.keyboard(.undoRemoveFromLine), context: context, bindings: bindings).keyHint, "", "Backspace deletes the selected annotation")
        try bindings.set([KeyShortcut(keyCode: 4, modifiers: 0, keyLabel: "H")], for: .pin)
        XCTAssertEqual(try command(.keyboard(.pin), context: context, bindings: bindings).keyHint, "", "The native marker tool consumes H before preview pin dispatch")
    }

    func testCatalogToolSequencesFollowEffectiveRemappedBindings() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        try bindings.set([KeyShortcut(keyCode: 49, modifiers: controlKey | optionKey, keyLabel: "Space")], for: .preview)
        try bindings.set([KeyShortcut(keyCode: 46, modifiers: controlKey | optionKey, keyLabel: "M")], for: .markup)
        try bindings.set([KeyShortcut(keyCode: 4, modifiers: controlKey | optionKey, keyLabel: "H")], for: .markupMarker)
        var context = ActionBarCatalog.Context()
        context.selectedCount = 1; context.kind = .image; context.hasFile = true
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "⌃⌥Space → ⌃⌥M → ⌃⌥H")
        context.origin = .shelfPreview
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "⌃⌥M → ⌃⌥H")
        context.isMarkupEditing = true
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "⌃⌥H")
        try bindings.set([], for: .preview)
        context.origin = .line; context.isMarkupEditing = false
        XCTAssertEqual(try command(.keyboard(.markupMarker), context: context, bindings: bindings).keyHint, "", "A disabled prefix cannot be presented as an executable key sequence")
    }

    func testApplicationCatalogTeachesScopedShelfShortcutsWithoutEnablingUnavailableActions() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let bindings = KeyboardBindings(defaults: fixture.defaults)
        var context = ActionBarCatalog.Context()
        context.origin = .application
        let pin = try command(.keyboard(.pin), context: context, bindings: bindings)
        XCTAssertFalse(pin.isEnabled)
        XCTAssertEqual(pin.keyHint, bindings.title(.pin, in: .line))
        XCTAssertEqual(pin.subtitle, L("On the line"))
        XCTAssertEqual(try command(.keyboard(.library), context: context, bindings: bindings).keyHint, "L")
        XCTAssertEqual(try command(.keyboard(.searchShelf), context: context, bindings: bindings).keyHint, "⇧S")
        let marker = try command(.keyboard(.markupMarker), context: context, bindings: bindings)
        XCTAssertFalse(marker.isEnabled)
        XCTAssertEqual(marker.keyHint, "Space → M → H")
        XCTAssertFalse(try command(.keyboard(.trash), context: context, bindings: bindings).isEnabled)
        XCTAssertEqual(try command(.keyboard(.trash), context: context, bindings: bindings).keyHint, "⌦")
        context.origin = .shelfPreview; context.kind = .image; context.hasFile = true; context.selectedCount = 1
        XCTAssertEqual(try command(.keyboard(.trash), context: context, bindings: bindings).keyHint, "", "A real preview keeps its own native key ownership")
        try bindings.set([KeyShortcut(keyCode: 35, modifiers: controlKey | optionKey, keyLabel: "P")], for: .pin)
        context.origin = .application; context.kind = nil; context.hasFile = false; context.selectedCount = 0
        XCTAssertEqual(try command(.keyboard(.pin), context: context, bindings: bindings).keyHint, "⌃⌥P", "Learning hints remain current after remapping")
    }
}
