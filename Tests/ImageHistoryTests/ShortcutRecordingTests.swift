import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShortcutRecordingTests: HistoryTestCase {
    private final class Registry {
        var active = [UInt32: Int]()
        var blocked = Set<Int>()
        func make(_ key: Int, action: @escaping () -> Void = {}) -> HotKey {
            var id: UInt32 = 0
            return HotKey(keyCode: key, modifiers: 0, registration: .init(register: { code, _, identifier in
                id = identifier
                guard !self.blocked.contains(code), !self.active.values.contains(code) else { return OSStatus(eventHotKeyExistsErr) }
                self.active[identifier] = code; return noErr
            }, unregister: { self.active[id] = nil }), action: action)
        }
    }
    private struct Contract: Decodable { let commonGlobalActions: [String]; let exitReasons: [String] }
    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/shortcut-recording.json")))
    }
    private func key(_ code: UInt16, _ value: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
    }
    func testOwnedGlobalLeaseSuspendsAllAndBlocksStaleCallbacksUntilLastRecorderEnds() throws {
        let registry = Registry(); var actions = [Int]()
        let globals = (1...(try contract()).commonGlobalActions.count).map { index in registry.make(index) { actions.append(index) } }
        registry.active[UInt32.max] = 99 // Represents an unrelated registration, never owned by HotKey.
        for value in globals { HotKey.dispatch(value.identifier) }
        XCTAssertEqual(actions, [1,2,3,4,5]); actions = []
        let staleEvents = registry.active.keys.filter { $0 != UInt32.max }
        let first = HotKey.suspendAll(); var second: HotKey.Suspension? = HotKey.suspendAll()
        XCTAssertNotNil(second)
        XCTAssertEqual(registry.active, [UInt32.max: 99])
        for value in globals { HotKey.dispatch(value.identifier) }
        XCTAssertTrue(actions.isEmpty)
        first.resume(); first.resume(); XCTAssertEqual(registry.active, [UInt32.max: 99])
        second = nil; XCTAssertEqual(registry.active.count, 6)
        for event in staleEvents { HotKey.dispatchEvent(event) }; XCTAssertTrue(actions.isEmpty)
        for value in globals { XCTAssertTrue(value.isRegistered); HotKey.dispatch(value.identifier); value.invalidate() }
        XCTAssertEqual(actions, [1,2,3,4,5]); XCTAssertEqual(registry.active, [UInt32.max: 99])
    }
    func testInvalidatedAndReleasedBindingsAreNotResurrectedByLateLeaseCompletion() {
        let registry = Registry(), retained = registry.make(1)
        var released: HotKey? = registry.make(2)
        XCTAssertTrue(released?.isRegistered == true)
        let lease = HotKey.suspendAll(); retained.invalidate(); released = nil; lease.resume()
        XCTAssertTrue(registry.active.isEmpty); XCTAssertFalse(retained.isRegistered)
    }
    func testRejectedReplacementKeepsPreviouslyWorkingBindingAfterRecording() {
        let registry = Registry(), previous = registry.make(1)
        let lease = HotKey.suspendAll(); XCTAssertFalse(previous.isRegistered)
        lease.resume(); registry.blocked.insert(2)
        let candidate = registry.make(2)
        XCTAssertFalse(candidate.isRegistered); XCTAssertTrue(previous.isRegistered)
        XCTAssertEqual(Array(registry.active.values), [1]); previous.invalidate(); candidate.invalidate()
    }
    func testRecorderAcceptsCurrentCombinationAndRestoresGlobalsBeforeCompletion() {
        _ = NSApplication.shared
        let registry = Registry(), global = registry.make(Int(kVK_ANSI_S))
        let recorder = ShortcutRecorder(); var accepted: KeyShortcut?, restored = false
        recorder.onFinish = { value in accepted = value; restored = global.isRegistered }
        recorder.beginRecording(); XCTAssertFalse(global.isRegistered)
        XCTAssertTrue(recorder.window.performKeyEquivalent(with: key(UInt16(kVK_ANSI_S), "s", [.control,.option])))
        XCTAssertTrue(recorder.window.performKeyEquivalent(with: key(UInt16(kVK_Return), "\r")))
        XCTAssertEqual(accepted?.keyCode, Int(kVK_ANSI_S)); XCTAssertTrue(restored); XCTAssertTrue(global.isRegistered)
        global.invalidate()
    }
    func testScopeExceptionAndRecorderDeallocationRestoreGlobals() {
        enum SyntheticFailure: Error { case stopped }
        _ = NSApplication.shared
        let registry = Registry(), global = registry.make(1)
        do {
            let lease = HotKey.suspendAll()
            XCTAssertFalse(global.isRegistered); _ = lease
            throw SyntheticFailure.stopped
        } catch {}
        XCTAssertTrue(global.isRegistered)
        weak var released: ShortcutRecorder?
        autoreleasepool {
            var recorder: ShortcutRecorder? = ShortcutRecorder()
            released = recorder
            recorder?.beginRecording(); XCTAssertFalse(global.isRegistered)
            recorder = nil
        }
        XCTAssertNil(released); XCTAssertTrue(global.isRegistered); global.invalidate()
    }
    func testRestoreFailureReportsOnceWithoutStealingAnotherOwner() {
        let registry = Registry(), global = registry.make(1); var warnings = 0
        let lease = HotKey.suspendAll(onRestoreFailure: { warnings += 1 })
        registry.blocked.insert(1); lease.resume(); lease.resume()
        XCTAssertEqual(warnings, 1); XCTAssertFalse(global.isRegistered); XCTAssertTrue(registry.active.isEmpty)
        registry.blocked.remove(1); global.invalidate()
    }
    func testRecorderCancelFocusLossAndWindowCloseReleaseTheirLeases() throws {
        _ = NSApplication.shared
        for reason in try contract().exitReasons {
            let registry = Registry(), global = registry.make(1), recorder = ShortcutRecorder(allowPlain: true)
            var completions = 0
            recorder.onFinish = { value in XCTAssertNil(value); completions += 1 }
            recorder.beginRecording(); XCTAssertFalse(global.isRegistered)
            if reason == "focus" { recorder.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: recorder.window)) }
            else if reason == "close" { recorder.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: recorder.window)) }
            else { XCTAssertTrue(recorder.window.performKeyEquivalent(with: key(UInt16(kVK_Escape), "\u{1B}"))) }
            XCTAssertTrue(global.isRegistered); XCTAssertEqual(completions, 1); global.invalidate()
        }
    }
}
