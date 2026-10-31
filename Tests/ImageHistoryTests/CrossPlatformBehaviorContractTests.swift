import AppKit
import CryptoKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Runs the shared product contract against the real Mac model and key router.
/// Synthetic data only: no AX queries, windows, system pasteboard or posted keys.
@MainActor final class CrossPlatformBehaviorContractTests: HistoryTestCase {
    private var checkout: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func required<T>(_ value: Any?, _ type: T.Type = T.self) throws -> T {
        guard let result = value as? T else { throw CocoaError(.coderReadCorrupt) }
        return result
    }
    private func shelf(_ kind: String) throws -> Shelf {
        switch kind { case "image": return .images; case "text": return .texts; case "link": return .links
        default: throw CocoaError(.coderReadCorrupt) }
    }
    private func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    private func revision() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["GITHUB_SHA"] { return value }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]; process.currentDirectoryURL = checkout
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func snapshot(_ line: Line, aliases: [UUID: String]) -> [String: Any] {
        let focused: UUID?
        switch line.activeShelf { case .images: focused = line.focusedID; case .texts: focused = line.texts.focusedID; case .links: focused = line.links.focusedID }
        let selected = line.selectedIDs.union(line.texts.selectedIDs).union(line.links.selectedIDs)
        return ["activeKind": line.activeShelf.libraryKind.rawValue,
                "focused": focused.map { aliases[$0] ?? "unexpected-id" } as Any? ?? NSNull(),
                "selected": selected.map { aliases[$0] ?? "unexpected-id" }.sorted(),
                "visibleKinds": line.presentation.shelves.map { $0.libraryKind.rawValue },
                "searchEditing": line.searchEditingShelf != nil]
    }
    func testSharedShelfBehaviorContract() throws {
        let data = try Data(contentsOf: checkout.appendingPathComponent("contracts/shelf-behavior.json"))
        let contract = try required(JSONSerialization.jsonObject(with: data), [String: Any].self)
        let itemSets = try required(contract["itemSets"], [String: [[String: Any]]].self)
        let scenarios = try required(contract["scenarios"], [[String: Any]].self)
        var observations = [[String: Any]](), errors = [String]()
        for scenario in scenarios {
            let id = try required(scenario["id"], String.self)
            let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
            let store = try LibraryStore(defaults: fixture.defaults, inbox: fixture.inbox, now: { fixture.date })
            let values = try XCTUnwrap(itemSets[try required(scenario["itemSet"], String.self)])
            var aliases = [UUID: String]()
            // The JSON records are newest first; insert oldest first into the
            // actual store so both platforms observe the same ordering.
            for value in values.reversed() {
                let alias = try required(value["id"], String.self), kind = try required(value["kind"], String.self)
                let record: LibraryRecord
                switch kind {
                case "image": record = try store.captureImage(fixture.image(name: "Contract-\(alias).png"))
                case "text": record = try XCTUnwrap(store.captureText(try required(value["text"], String.self)))
                case "link": record = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/contract/\(alias)")))
                default: throw CocoaError(.coderReadCorrupt)
                }
                aliases[record.id] = alias; fixture.date += 1
            }
            var effects = [String](), linkLabels = [UUID: String]()
            let line = Line(defaults: fixture.defaults, inbox: fixture.inbox, now: { fixture.date }, breeze: false,
                copyImage: { _ in effects.append("copy") }, copyText: { _ in effects.append("copy") }, library: store)
            let visible = try required(scenario["visibleKinds"], [String].self).map { try shelf($0) }
            line.setPresentation(try XCTUnwrap(ShelfPresentation.containing(Set(visible))), requestFocus: false)
            for kind in try required(scenario["pinnedOnlyKinds"], [String].self) {
                switch try shelf(kind) { case .images: line.setFavoritesOnly(true); case .texts: line.texts.setFavoritesOnly(true); case .links: line.links.setFavoritesOnly(true) }
            }
            let keyboard = LineKeyboard(line: line, onCopy: { _ in effects.append("copy") }, onPreview: { _ in effects.append("preview") },
                onClose: {}, onTextCopy: { _ in effects.append("copy") }, onTextPreview: { _ in effects.append("preview") },
                onLinkPreview: { _ in effects.append("preview") })
            for (index, step) in try required(scenario["steps"], [[String: Any]].self).enumerated() {
                // Library writes (pin, take down) and image-row changes count as effects too.
                effects.removeAll(); let revisionBefore = store.revision, imagesBefore = line.items.map { "\($0.id)-\($0.pinned)" }
                var copied: [String: Any]?
                switch try required(step["action"], String.self) {
                case "open": line.revealed = true
                case "close": line.revealed = false
                case "remap":
                    let action = try XCTUnwrap(KeyboardAction(rawValue: try required(step["binding"], String.self)))
                    if step["key"] is NSNull { try line.keyboardBindings.reset(action) }
                    else {
                        let value = try required(step["key"], String.self)
                        guard value.isEmpty || value == "KeyX" else { throw CocoaError(.coderReadCorrupt) }
                        try line.keyboardBindings.set(value.isEmpty ? [] : [KeyShortcut(keyCode: 7, modifiers: 0, keyLabel: "X")], for: action)
                    }
                case "key":
                    guard try required(step["code"], String.self) == "KeyX" else { throw CocoaError(.coderReadCorrupt) }
                    _ = keyboard.handle(try key(7, characters: "x"))
                case "up": _ = keyboard.handle(try key(126))
                case "down": _ = keyboard.handle(try key(125))
                case "left": _ = keyboard.handle(try key(123))
                case "right": _ = keyboard.handle(try key(124))
                case "toggle": _ = line.toggleShelf(try shelf(try required(step["kind"], String.self)))
                case "switchShelf": _ = keyboard.handle(try key(48))
                case "command":
                    let event: NSEvent
                    switch try required(step["code"], String.self) {
                    case "Enter": event = try key(36)
                    case "KeyS": event = try key(1, characters: "s")
                    case "KeyP": event = try key(35, characters: "p")
                    case "Space": event = try key(49)
                    case "KeyC": event = try key(8, characters: "c", flags: .command)
                    default: throw CocoaError(.coderReadCorrupt)
                    }
                    _ = keyboard.handle(event)
                case "copyLink":
                    // The copy goes through the real store; the report names the stored link it resolved to (numbered by first appearance) and its address.
                    let record = try store.captureLink(try XCTUnwrap(URL(string: try required(step["url"], String.self))))
                    if linkLabels[record.id] == nil { linkLabels[record.id] = "link-\(linkLabels.count + 1)" }
                    copied = ["link": ["item": linkLabels[record.id] ?? "unexpected-id", "address": record.originalURL ?? ""]]
                case "openSearch": line.beginShelfSearch()
                case "finishSearch":
                    line.finishShelfSearchEditing(line.activeShelf)
                    let deadline = Date().addingTimeInterval(3)
                    while line.shelfSearchIsSearching, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                default: throw CocoaError(.coderReadCorrupt)
                }
                var actual = copied ?? snapshot(line, aliases: aliases)
                let expected = try required(step["expect"], [String: Any].self)
                if step["action"] as? String == "command" {
                    if store.revision != revisionBefore { effects.append("library") }
                    if line.items.map({ "\($0.id)-\($0.pinned)" }) != imagesBefore { effects.append("images") }
                    actual["effects"] = effects.sorted()
                }
                observations.append(["scenarioId": id, "step": index, "actual": actual])
                let matches = NSDictionary(dictionary: actual).isEqual(to: expected)
                if !matches { errors.append("\(id):\(index)") }
                XCTAssertTrue(matches, "Shared contract \(id) step \(index): expected \(expected), received \(actual)")
            }
        }
        let report: [String: Any] = ["schemaVersion": 1, "contractId": try required(contract["contractId"], String.self),
            "contractSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "platform": "macos", "hostPlatform": "darwin", "mode": "model", "sourceRevision": try revision(),
            "observations": observations, "errors": errors]
        if let destination = ProcessInfo.processInfo.environment["CLIPBOARDLINE_PARITY_REPORT"], !destination.isEmpty {
            let path = URL(fileURLWithPath: destination, relativeTo: checkout)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
        }
        XCTAssertTrue(!observations.isEmpty && errors.isEmpty)
    }
}
