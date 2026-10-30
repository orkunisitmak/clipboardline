import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class SettingsTests: HistoryTestCase {
    func testOpeningSettingsPreservesPreferencesHistoryAndSelection() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium }
        let line = f.line()
        line.hang(try f.image(), quietly: true)
        line.texts.add("Synthetic settings test")
        line.select(try XCTUnwrap(line.newestID))
        let before = f.defaults.persistentDomain(forName: f.suite)! as NSDictionary
        let ids = line.items.map(\.id), selected = line.selectedIDs
        let model = SettingsModel(line: line, allowsSystemChanges: false)
        let controller = SettingsWindowController(model: model)
        XCTAssertTrue(controller.window?.title.contains(AppIdentity.name) == true)
        XCTAssertFalse(model.allowsSystemChanges)
        model.refresh()
        XCTAssertTrue(before.isEqual(to: f.defaults.persistentDomain(forName: f.suite)!))
        XCTAssertEqual(line.items.map(\.id), ids)
        XCTAssertEqual(line.selectedIDs, selected)
        XCTAssertEqual(line.texts.entries.count, 1)
        controller.close()
    }

    func testClosedSettingsKeepNoViewThatWatchesTheLine() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let controller = SettingsWindowController(model: SettingsModel(line: f.line(), allowsSystemChanges: false))
        let window = try XCTUnwrap(controller.window)
        let isHosting = { String(describing: type(of: window.contentView!)).hasPrefix("NSHostingView") }
        XCTAssertTrue(isHosting())
        controller.close()
        XCTAssertFalse(isHosting(), "A closed Settings window must not keep re-rendering")
    }

    func testReopenedSettingsKeepCleanupChoiceAndHandleUpdateRequestOnce() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let model = SettingsModel(line: f.line(), allowsSystemChanges: false)
        let controller = SettingsWindowController(model: model)
        model.updatesRequest += 1
        XCTAssertEqual(model.section, .updates)
        model.section = .history
        model.historyCleanupKind = .text
        controller.close()
        controller.present()
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(String(describing: type(of: content)).hasPrefix("NSHostingView"), "Reopening must rebuild the view")
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // The rebuilt view must not replay the old request, and the chosen
        // copies to clear are kept.
        XCTAssertEqual(model.section, .history)
        XCTAssertEqual(model.historyCleanupKind, .text)
        controller.close()
    }

    func testSettingsBindingsApplyAppearanceWithoutMovingFocusOrDroppingHistory() throws {
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium }
        let line = f.line()
        line.hang(try f.image(), quietly: true)
        line.texts.add("Synthetic text")
        line.select(try XCTUnwrap(line.newestID))
        let selected = line.selectedIDs
        var focusRequests = 0
        line.onFocusRequested = { focusRequests += 1 }
        let model = SettingsModel(line: line, allowsSystemChanges: false)
        model.setSize = { line.setSize($0) }
        let size = model.binding(get: { line.size }, set: model.setSize)
        let shelves = model.binding(get: { line.presentation }, set: { line.setPresentation($0, requestFocus: false) })
        size.wrappedValue = .small
        shelves.wrappedValue = .both
        XCTAssertEqual(f.line().size, .small)
        XCTAssertEqual(f.line().presentation, .both)
        XCTAssertEqual(line.items.count, 1)
        XCTAssertEqual(line.texts.entries.count, 1)
        XCTAssertEqual(line.selectedIDs, selected)
        XCTAssertEqual(focusRequests, 0)
    }

    func testCompactMenuIdentifiesTheAppAndKeepsDailyActions() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        let delegate = AppDelegate(line: line, watchesFiles: false)
        let menu = NSMenu(); delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            AppIdentity.name, L("Show line"), L("Library…"), L("Actions") + "…  " + line.keyboardBindings.title(.commandPalette), L("Copy latest image"), L("Open screenshots folder"),
            L("Settings…"), L("Check for updates…"), String(format: L("Quit %@"), AppIdentity.name)])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == L("Copy latest image") }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == L("Check for updates…") }).isEnabled)
        XCTAssertEqual(menu.items.filter { $0.submenu != nil }.count, 0)
    }
}
