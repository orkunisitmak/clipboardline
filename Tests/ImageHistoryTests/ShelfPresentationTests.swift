import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShelfPresentationTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate(), "Native shelf presentation did not settle")
    }

    func testNativeVisibilityKeepsWindowContentAndHitCoordinatesFixed() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 780))
        let child = NSView(frame: NSRect(x: 30, y: 50, width: 100, height: 80))
        content.addSubview(child)
        let panel = LinePanel(content: content)
        defer { panel.contentView = nil }
        panel.setFrame(NSRect(x: -900, y: 250, width: 900, height: 780), display: false)
        let originalFrame = panel.frame, originalBounds = content.bounds, originalContentFrame = content.frame
        let point = child.convert(NSPoint(x: 40, y: 40), to: content)
        let originalHit = content.hitTest(point)
        XCTAssertFalse(panel.isVisible, "Preparation must happen before the caller orders the shelf front")
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12), "The first committed frame starts above the display")
        XCTAssertNotNil(panel.contentView?.layer)
        XCTAssertTrue(panel.contentView?.layer?.masksToBounds == true)
        for on in [false, true, false, true] {
            panel.setShelfRevealed(on, animated: false)
            XCTAssertEqual(panel.frame, originalFrame, "Visibility must not move into a display above the shelf")
            XCTAssertEqual(content.bounds, originalBounds)
            XCTAssertEqual(content.frame, originalContentFrame)
            XCTAssertTrue(content.superview === panel.contentView, "The retained hosting view lives inside the fixed compositor")
            XCTAssertTrue(content.hitTest(point) === originalHit)
            XCTAssertEqual(panel.shelfModelOffset, on ? 0 : -(panel.contentHeight + 12))
            XCTAssertEqual(panel.alphaValue, 1, "Reveal must move the layer tree rather than fade the window")
            XCTAssertFalse(panel.isShelfTransitioning)
        }
        panel.setShelfRevealed(false, animated: false)
        panel.contentHeight = 3 * Layout.panelHeight
        XCTAssertEqual(panel.shelfModelOffset, -(3 * Layout.panelHeight + 12), "A hidden row-count change must remain completely above the display")
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertEqual(content.bounds, originalBounds)
        panel.setShelfRevealed(true, animated: false)
        panel.contentHeight = Layout.panelHeight
        XCTAssertEqual(panel.shelfModelOffset, 0, "Visible capacity changes must retain their resting position")
    }

    func testRapidVisibilityReversalCannotRunAnEarlierCloseCompletion() throws {
        _ = NSApplication.shared
        for reduceMotion in [false, true] {
            let panel = LinePanel(content: NSView(), reduceMotion: { reduceMotion })
            defer { panel.contentView = nil }
            var closed = 0, opened = 0
            var scrolls = 0, mouseCaptures = 0, keys = 0
            panel.onScroll = { _, _, _ in scrolls += 1 }
            panel.onBeforeMouseKeyFocus = { mouseCaptures += 1 }
            let cgWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
            let wheel = try XCTUnwrap(NSEvent(cgEvent: cgWheel))
            // Both requests happen in one event turn, as with a queued global
            // shortcut. An earlier asynchronous completion must not hide the row.
            panel.setShelfRevealed(false) { closed += 1 }
            panel.setShelfRevealed(true) { opened += 1 }
            XCTAssertEqual(panel.shelfModelOffset, 0)
            XCTAssertEqual(panel.isShelfTransitioning, !reduceMotion)
            if !reduceMotion {
                XCTAssertTrue(panel.ignoresMouseEvents, "Model hit coordinates must not accept pointer actions while the cards move")
                XCTAssertNotNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(click)
                panel.sendEvent(wheel)
                XCTAssertEqual(mouseCaptures, 0, "Queued pointer events must not capture a field at the untranslated model position")
                XCTAssertEqual(scrolls, 0, "Queued scrolling must not navigate the untranslated shelf row")
                panel.keyboardFocusAllowed = true
                panel.onKey = { _ in keys += 1; return true }
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
                XCTAssertTrue(panel.routeKey(key, isFocused: true))
                XCTAssertEqual(keys, 1, "Keyboard browsing remains immediate while the compositor animates")
            }
            wait { opened == 1 }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.shelfModelOffset, 0)
            XCTAssertFalse(panel.isShelfTransitioning)
            XCTAssertNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
            panel.sendEvent(wheel)
            XCTAssertEqual(scrolls, 1, "Normal row scrolling resumes after the compositor settles")
            // Reverse a real open-to-close request before its completion can
            // order the panel out. Detached layers do not promise a rendered
            // presentation position, so visual continuity is a live-test gate.
            panel.setShelfRevealed(false) { closed += 1 }
            panel.setShelfRevealed(true) { opened += 1 }
            wait { opened == 2 }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(panel.shelfModelOffset, 0)
            panel.setShelfRevealed(false) { closed += 1 }
            wait { closed == 1 }
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
            XCTAssertFalse(panel.isShelfTransitioning)
        }
    }

    func testReducedMotionIsImmediateAndPresentationDoesNotClaimKeyboardOwnership() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView(), reduceMotion: { true })
        defer { panel.contentView = nil }
        var captures = 0
        panel.onBeforeMouseKeyFocus = { captures += 1 }
        panel.keyboardFocusAllowed = false
        panel.setShelfRevealed(false)
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.isShelfTransitioning)
        panel.setShelfRevealed(true)
        XCTAssertEqual(panel.shelfModelOffset, 0)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.isShelfTransitioning)
        XCTAssertNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.keyboardFocusAllowed)
        XCTAssertEqual(captures, 0, "Exact paste-target capture stays at the caller's focus boundary")
        panel.keyboardFocusAllowed = true
        panel.setShelfRevealed(false)
        XCTAssertTrue(panel.keyboardFocusAllowed, "The AppDelegate still owns focus release and return")
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
    }

    func testReplacementPanelTakesOverContentCallbacksAndShownState() throws {
        _ = NSApplication.shared
        for revealed in [false, true] {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 2 * Layout.panelHeight))
            let child = NSView(frame: NSRect(x: 30, y: 50, width: 100, height: 80))
            content.addSubview(child)
            let old = LinePanel(content: content, reduceMotion: { true })
            var scrolls = 0, scrollLocations = 0, keys = 0, commandKeys = 0, mouseCaptures = 0
            old.onScroll = { _, _, _ in scrolls += 1 }
            old.onScrollLocation = { _ in scrollLocations += 1 }
            old.onKey = { _ in keys += 1; return true }
            old.onCommandKey = { _ in commandKeys += 1; return true }
            old.onBeforeMouseKeyFocus = { mouseCaptures += 1 }
            old.searchEditorTarget = { nil }
            old.keyboardFocusAllowed = true
            old.contentHeight = 2 * Layout.panelHeight
            old.setFrame(NSRect(x: -900, y: 250, width: 900, height: 2 * Layout.panelHeight), display: false)
            old.setShelfRevealed(revealed, animated: false)
            old.ignoresMouseEvents = !revealed
            let frame = old.frame, contentFrame = content.frame

            let fresh = old.makeReplacement()
            defer { fresh.contentView = nil; old.contentView = nil }
            XCTAssertFalse(fresh === old)
            XCTAssertFalse(old.isVisible, "The window macOS left behind is ordered out")
            XCTAssertTrue(old.contentView?.subviews.isEmpty == true, "The content moves rather than being shown twice")
            XCTAssertTrue(content.superview === fresh.contentView)
            XCTAssertTrue(child.superview === content)
            XCTAssertEqual(content.frame, contentFrame)
            XCTAssertEqual(fresh.frame, frame)
            XCTAssertEqual(fresh.contentHeight, 2 * Layout.panelHeight)
            XCTAssertEqual(fresh.shelfModelOffset, revealed ? 0 : -(2 * Layout.panelHeight + 12),
                           "A shelf that was down stays down; a tucked one stays above the display")
            XCTAssertEqual(fresh.ignoresMouseEvents, !revealed)
            XCTAssertTrue(fresh.keyboardFocusAllowed)
            XCTAssertNotNil(fresh.searchEditorTarget)
            XCTAssertTrue(fresh.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertEqual(fresh.level, .floating)

            let cgWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
            fresh.sendEvent(try XCTUnwrap(NSEvent(cgEvent: cgWheel)))
            XCTAssertEqual(scrolls, 1); XCTAssertEqual(scrollLocations, 1)
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
            XCTAssertTrue(fresh.routeKey(key, isFocused: true)); XCTAssertEqual(keys, 1)
            let commandKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
            XCTAssertTrue(fresh.routeKey(commandKey, isFocused: true)); XCTAssertEqual(commandKeys, 1)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            fresh.prepareForMouseKeyFocus(click, isFocused: false); XCTAssertEqual(mouseCaptures, 1)
            fresh.setShelfRevealed(!revealed, animated: false)
            XCTAssertEqual(fresh.shelfModelOffset, revealed ? -(2 * Layout.panelHeight + 12) : 0)
        }
    }

    /// Reproduces the window server fault behind "the shelf only comes down
    /// on one desktop": the shelf window is still visible to AppKit, but it
    /// belongs to one Space only, so ordering it in on another does nothing.
    /// Needs a session with at least two Spaces; otherwise there is nothing
    /// to be left on.
    func testShelfLeftOnAnotherSpaceIsReplacedByOneOnTheActiveSpace() throws {
        _ = NSApplication.shared
        let connection = spaceTestConnection()
        let active = spaceTestActiveSpace(connection)
        func spaces(_ window: NSWindow) -> [UInt64] {
            spaceTestSpaces(connection, 7, [window.windowNumber] as CFArray) as? [UInt64] ?? []
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        let old = LinePanel(content: content, reduceMotion: { true })
        defer { old.orderOut(nil); old.contentView = nil }
        old.setFrame(NSRect(x: 0, y: 0, width: 2, height: 2), display: false)
        old.orderFrontRegardless()
        wait { !spaces(old).isEmpty }
        let joined = spaces(old)
        guard let other = joined.first(where: { $0 != active }) else {
            #if !STANDALONE_TESTS
            throw XCTSkip("This session has a single Space")
            #else
            print("SKIP testShelfLeftOnAnotherSpaceIsReplacedByOneOnTheActiveSpace: single Space")
            return
            #endif
        }
        XCTAssertTrue(joined.contains(active), "A new shelf joins every Space")
        old.orderOut(nil)
        spaceTestRemove(connection, [old.windowNumber] as CFArray, joined.filter { $0 != other } as CFArray)
        wait { spaces(old) == [other] }
        XCTAssertFalse(old.isOnActiveSpace, "The fault is detectable while the shelf is ordered out")
        old.orderFrontRegardless()
        XCTAssertTrue(old.isVisible)
        XCTAssertFalse(old.isOnActiveSpace, "Ordering the stuck window in does not bring it to this Space")
        old.setShelfRevealed(true, animated: false)

        let fresh = old.makeReplacement()
        defer { fresh.orderOut(nil); fresh.contentView = nil }
        XCTAssertTrue(fresh.isOnActiveSpace, "The replacement is checked before its reveal and passes")
        fresh.orderFrontRegardless()
        XCTAssertTrue(fresh.isOnActiveSpace)
        XCTAssertTrue(content.superview === fresh.contentView)
        XCTAssertEqual(fresh.shelfModelOffset, 0)
        wait { Set(spaces(fresh)).isSuperset(of: joined) }
    }
}

@_silgen_name("CGSMainConnectionID")
private func spaceTestConnection() -> Int32
@_silgen_name("CGSGetActiveSpace")
private func spaceTestActiveSpace(_ connection: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows")
private func spaceTestSpaces(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
@_silgen_name("CGSRemoveWindowsFromSpaces")
private func spaceTestRemove(_ connection: Int32, _ windows: CFArray, _ spaces: CFArray)
