import AppKit
import Carbon

/// Independent global shortcuts through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
final class HotKey {
    struct Registration {
        var register: (Int, Int, UInt32) -> OSStatus
        var unregister: () -> Void
    }
    private final class Weak { weak var value: HotKey?; init(_ value: HotKey) { self.value = value } }
    final class Suspension {
        private var id: UUID?
        private let onRestoreFailure: (() -> Void)?
        fileprivate init(_ id: UUID, onRestoreFailure: (() -> Void)?) { self.id = id; self.onRestoreFailure = onRestoreFailure }
        func resume() {
            guard let id else { return }; self.id = nil
            if !HotKey.resume(id) { onRestoreFailure?() }
        }
        deinit { resume() }
    }
    private var eventID: UInt32?
    private var ref: EventHotKeyRef?
    private var registered = false
    private var invalidated = false
    private let keyCode: Int
    private let modifiers: Int
    private let registration: Registration?
    private let action: () -> Void
    let identifier: UInt32
    private static var nextID: UInt32 = 1
    private static var nextEventID: UInt32 = 1
    private static var events: [UInt32: Weak] = [:]
    private static var owned: [UInt32: Weak] = [:]
    private static var suspensions = Set<UUID>()
    private static var suspendedIDs = Set<UInt32>()
    private static var handler: EventHandlerRef?
    private(set) var registrationStatus: OSStatus = noErr
    var isRegistered: Bool { registered && registrationStatus == noErr }

    /// Releases only this process's owned hotkeys. Nested recorders keep them
    /// released until the final lease ends; stale OS callbacks cannot fire.
    static func suspendAll(onRestoreFailure: (() -> Void)? = nil) -> Suspension {
        let id = UUID(); suspensions.insert(id)
        if suspensions.count == 1 {
            for value in owned.values {
                guard let value = value.value, value.isRegistered else { continue }
                suspendedIDs.insert(value.identifier); value.pause()
            }
        }
        return Suspension(id, onRestoreFailure: onRestoreFailure)
    }
    private static func resume(_ id: UUID) -> Bool {
        guard suspensions.remove(id) != nil, suspensions.isEmpty else { return true }
        let values = suspendedIDs.compactMap { owned[$0]?.value }
        suspendedIDs.removeAll()
        for value in values { value.registerIfAllowed() }
        return values.allSatisfy { $0.isRegistered }
    }
    static func dispatch(_ identifier: UInt32) {
        guard suspensions.isEmpty, let value = owned[identifier]?.value, value.isRegistered else { return }
        value.action()
    }
    static func dispatchEvent(_ eventID: UInt32) {
        guard let value = events[eventID]?.value, value.eventID == eventID else { return }
        dispatch(value.identifier)
    }
    init(keyCode: Int, modifiers: Int, registration: Registration? = nil, action: @escaping () -> Void) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.registration = registration; self.action = action
        identifier = Self.nextID; Self.nextID += 1
        Self.owned[identifier] = Weak(self)
        if !Self.suspensions.isEmpty { Self.suspendedIDs.insert(identifier) }
        registerIfAllowed()
    }
    private func registerIfAllowed() {
        guard !invalidated, !registered, Self.suspensions.isEmpty else { return }
        let newEventID = Self.nextEventID; Self.nextEventID += 1
        if let registration {
            registrationStatus = registration.register(keyCode, modifiers, newEventID)
            registered = registrationStatus == noErr
            if registered { eventID = newEventID; Self.events[newEventID] = Weak(self) }
            return
        }
        registrationStatus = noErr
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            registrationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID(signature: 0, id: 0)
                guard let event,
                      GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                      key.signature == 0x5445_4E44 else { return noErr }
                let id = key.id
                DispatchQueue.main.async { HotKey.dispatchEvent(id) }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        guard registrationStatus == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x5445_4E44), id: newEventID)
        registrationStatus = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
            GetApplicationEventTarget(), 0, &ref)
        registered = ref != nil && registrationStatus == noErr
        if registered { eventID = newEventID; Self.events[newEventID] = Weak(self) }
    }
    private func pause() {
        guard registered else { return }
        if let registration { registration.unregister() }
        else if let ref { UnregisterEventHotKey(ref) }
        if let eventID { Self.events[eventID] = nil }; eventID = nil
        ref = nil; registered = false
    }
    convenience init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        guard shortcut.isUsable else { return nil }
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: action)
        guard isRegistered else { return nil }
    }
    func invalidate() {
        invalidated = true; pause(); Self.owned[identifier] = nil; Self.suspendedIDs.remove(identifier)
    }
    deinit { invalidate() }
}

/// The shortcut that shows and hides the line: ⌃⌥T unless changed, or none.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// The key as typed, for the menu: "t", " ", "1".
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option], key: "t")

    private static let defaultsKey = "shortcut"

    /// The user's choice. Nil means no shortcut at all.
    static var current: Shortcut? {
        get {
            guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return standard }
            guard let code = saved["keyCode"] as? Int, let flags = saved["modifiers"] as? UInt,
                  let key = saved["key"] as? String else { return nil }
            let value = Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: flags), key: key)
            return value.isUsable ? value : nil
        }
        set {
            UserDefaults.standard.set(newValue.map {
                ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any]
            } ?? [:], forKey: defaultsKey)
        }
    }

    /// From a key press, if it makes a usable global shortcut: it needs
    /// Command, Control or Option, so typing alone never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: flags, key: key)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var isUsable: Bool {
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return (0..<128).contains(keyCode) && !key.isEmpty
            && modifiers.subtracting(allowed).isEmpty
            && !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// As macOS writes it in menus: ⌃⌥⇧⌘ and the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key == " " ? L("Space") : UInt16(exactly: keyCode).flatMap { KeyShortcut.keyNames[$0] } ?? key.uppercased())
    }
}

/// Asks for a new shortcut in a small window: the next key press with
/// Command, Control or Option becomes it. Escape cancels and Delete leaves
/// the line without a shortcut.
@MainActor
final class ToggleShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ToggleShortcutRecorder()

    var isRecording: Bool { window != nil }
    private var window: NSWindow?
    private var monitor: Any?
    private var done: ((Shortcut??) -> Void)?
    private var suspension: HotKey.Suspension?

    /// Calls back with the new shortcut, `.some(nil)` for none, or nil if
    /// cancelled.
    func record(onRestoreFailure: (() -> Void)? = nil, _ done: @escaping (Shortcut??) -> Void) {
        finish(nil)
        self.done = done
        suspension = HotKey.suspendAll(onRestoreFailure: onRestoreFailure)

        let title = NSTextField(labelWithString: L("Press the new shortcut"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: L("Escape cancels. Delete removes the shortcut."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Change Shortcut")
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if event.keyCode == UInt16(kVK_Escape) && plain {
                self.finish(nil)
            } else if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && plain {
                self.finish(.some(nil))
            } else if let shortcut = Shortcut(event: event) {
                self.finish(.some(shortcut))
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        finish(nil)
    }

    private func finish(_ result: Shortcut??) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = self.done
        self.done = nil
        window?.close()
        window = nil
        suspension?.resume(); suspension = nil
        done?(result)
    }
}
