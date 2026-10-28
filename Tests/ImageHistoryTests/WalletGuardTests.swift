import AppKit
import CryptoKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Wallet Guard: the shared contract executed against the shipped Mac
/// classifier, the actual text watcher, legacy text history and AppDelegate
/// admission. Every value is a public test vector or synthetic data that holds
/// no funds. Nothing touches the system pasteboard or displays a panel.
@MainActor private final class WalletGuardClipboard: ClipboardSource {
    var count = 910000
    var values = [[NSPasteboard.PasteboardType: Data]]()
    var changeCount: Int { count }
    var itemTypes: [[NSPasteboard.PasteboardType]] { values.map { Array($0.keys) } }
    func data(forType type: NSPasteboard.PasteboardType, at index: Int) -> Data? { values[index][type] }
    func copy(_ text: String) { count += 1; values = [[.string: Data(text.utf8)]] }
}

@MainActor final class WalletGuardTests: HistoryTestCase {
    private struct Contract: Decodable {
        struct Setting: Decodable { let `default`: Bool; let macOSDefaultsKey: String }
        struct Wordlist: Decodable { let count: Int; let sha256OfNewlineTerminatedList: String }
        struct Limits: Decodable {
            let maximumInspectedCharacters, maximumMnemonicRunWords, hijackWindowMs, lookalikePrefix, lookalikeSuffix, historyAddresses, sessionAddresses: Int
        }
        struct Expect: Decodable { let kind: String; let secret: String?; let format: String?; let chain: String? }
        struct Vector: Decodable { let name: String; let value: String; let expect: Expect }
        struct Alert: Decodable { let type: String; let original, replacement, address, similar: String? }
        struct StepExpect: Decodable { let save: Bool; let notice: String?; let alert: Alert? }
        struct Step: Decodable { let atMs: Double; let text: String; let context: String?; let turnedOffBefore: Bool?; let expect: StepExpect }
        struct Scenario: Decodable { let name: String; let enabled: Bool; let history: [String]; let steps: [Step] }
        let schemaVersion: Int
        let setting: Setting
        let wordlist: Wordlist
        let limits: Limits
        let notices: [String: String]
        let classify: [Vector]
        let scenarios: [Scenario]
    }

    private func contract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("contracts/wallet-guard.json")))
    }

    private func matches(_ result: WalletGuardClassification, _ expect: Contract.Expect) -> Bool {
        switch result {
        case .none: return expect.kind == "none"
        case let .secret(kind, format): return expect.kind == "secret" && expect.secret == kind.rawValue && expect.format == format
        case let .address(chain, _): return expect.kind == "address" && expect.chain == chain
        }
    }

    private func expected(_ alert: Contract.Alert?) -> WalletGuardAlert? {
        guard let alert else { return nil }
        if alert.type == "hijack" { return .hijack(original: alert.original ?? "", replacement: alert.replacement ?? "") }
        return .poisoning(address: alert.address ?? "", similar: alert.similar ?? "")
    }

    func testBundledWordlistAndLimitsMatchSharedContract() throws {
        let contract = try contract()
        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(BIP39English.words.count, contract.wordlist.count)
        XCTAssertEqual(Set(BIP39English.words).count, 2048)
        let digest = SHA256.hash(data: Data((BIP39English.words.joined(separator: "\n") + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, contract.wordlist.sha256OfNewlineTerminatedList)
        let limits = contract.limits
        XCTAssertEqual(limits.maximumInspectedCharacters, WalletGuardLimits.maximumInspectedCharacters)
        XCTAssertEqual(limits.maximumMnemonicRunWords, WalletGuardLimits.maximumMnemonicRunWords)
        XCTAssertEqual(Double(limits.hijackWindowMs) / 1000, WalletGuardLimits.hijackWindow)
        XCTAssertEqual(limits.lookalikePrefix, WalletGuardLimits.lookalikePrefix)
        XCTAssertEqual(limits.lookalikeSuffix, WalletGuardLimits.lookalikeSuffix)
        XCTAssertEqual(limits.historyAddresses, WalletGuardLimits.historyAddresses)
        XCTAssertEqual(limits.sessionAddresses, WalletGuardLimits.sessionAddresses)
        XCTAssertEqual(contract.setting.macOSDefaultsKey, WalletGuard.defaultsKey)
        let previous = UserDefaults.standard.object(forKey: WalletGuard.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: WalletGuard.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: WalletGuard.defaultsKey)
        XCTAssertEqual(WalletGuard.isEnabled, contract.setting.default)
    }

    func testKeccakMatchesPublishedDigests() {
        let hex: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(Keccak256.hash([])), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(hex(Keccak256.hash(Array("abc".utf8))), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        XCTAssertEqual(Keccak256.hash([UInt8](repeating: 0x61, count: 136)).count, 32)
    }

    func testSharedClassificationVectors() throws {
        for vector in try contract().classify {
            let result = WalletGuardClassifier.classify(vector.value)
            XCTAssertTrue(matches(result, vector.expect), "\(vector.name) -> \(result)")
        }
    }

    func testSharedScenariosWithInjectedClock() throws {
        for scenario in try contract().scenarios {
            var now: TimeInterval = 0
            let guardian = WalletGuard(now: { now })
            for (index, step) in scenario.steps.enumerated() {
                now = step.atMs / 1000
                if step.turnedOffBefore == true { guardian.settingChanged(false); guardian.settingChanged(true) }
                let verdict = guardian.inspect(step.text, enabled: scenario.enabled, context: step.context) { scenario.history }
                XCTAssertEqual(verdict.save, step.expect.save, "\(scenario.name) step \(index)")
                XCTAssertEqual(verdict.notice?.rawValue, step.expect.notice, "\(scenario.name) step \(index)")
                XCTAssertEqual(verdict.alert, expected(step.expect.alert), "\(scenario.name) step \(index)")
            }
        }
    }

    func testOversizedCopiesAreNotInspectedAndDenseNotesStayBounded() throws {
        let mnemonic = try XCTUnwrap(contract().classify.first?.value)
        XCTAssertEqual(WalletGuardClassifier.classify(mnemonic + String(repeating: " ", count: WalletGuardLimits.maximumInspectedCharacters)), .none)
        let words = BIP39English.words
        let dense = String((0..<400).map { index in words[(index % 2000)..<(index % 2000 + 40)].joined(separator: " ") }.joined(separator: " x ").prefix(WalletGuardLimits.maximumInspectedCharacters))
        let started = Date()
        _ = WalletGuardClassifier.classify(dense)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testHistoryComparisonIsBoundedAndSkipsUnusableRows() throws {
        let scenario = try XCTUnwrap(contract().scenarios.first { $0.name.hasPrefix("a lookalike of a history address") })
        let address = try XCTUnwrap(scenario.steps.first?.text), similar = scenario.history[1]
        let old = Array(repeating: "synthetic note", count: WalletGuardLimits.historyAddresses) + [similar]
        XCTAssertNil(WalletGuard().inspect(address, context: nil) { old }.alert)
        XCTAssertEqual(WalletGuard().inspect(address, context: nil) { [String(repeating: "x", count: 10000), similar] }.alert,
                       .poisoning(address: address, similar: similar))
    }

    /// The actual watcher with Wallet Guard as its admission step: secrets
    /// never reach text history, and addresses still do.
    func testWatcherWithholdsSecretsFromTextHistoryAndKeepsAddresses() throws {
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let history = fixture.texts(), source = WalletGuardClipboard(), guardian = WalletGuard()
        var verdicts = [WalletGuardVerdict]()
        let watcher = TextClipboardWatcher(source: source, onText: { history.add($0) }, capturesText: { true }, admits: { text in
            let verdict = guardian.inspect(text, context: nil) { history.entries.map(\.text) }
            verdicts.append(verdict); return verdict.save
        })
        defer { watcher.stop() }; watcher.start()
        let vectors = try contract().classify
        for vector in vectors { source.copy(vector.value); watcher.check() }
        let saved = Set(history.entries.map(\.text))
        for vector in vectors where vector.expect.kind == "secret" { XCTAssertFalse(saved.contains(vector.value), vector.name) }
        for vector in vectors where vector.expect.kind == "address" { XCTAssertTrue(saved.contains(vector.value), vector.name) }
        XCTAssertEqual(verdicts.filter { !$0.save }.count, vectors.filter { $0.expect.kind == "secret" }.count)
        let archives = (FileManager.default.enumerator(at: fixture.folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        for vector in vectors where vector.expect.kind == "secret" { XCTAssertFalse(archives.contains(vector.value), vector.name) }
    }

    /// AppDelegate's admission path: the persisted toggle, the shelf notice and
    /// the presented message, without a window or the system pasteboard.
    func testAppDelegateAdmissionRespectsSettingAndPresentsMessages() throws {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: WalletGuard.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: WalletGuard.defaultsKey) }
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let line = fixture.line(), app = AppDelegate(line: line, watchesFiles: false)
        var shown = [WalletGuardMessage]()
        app.presentWalletGuard = { shown.append($0) }
        let contract = try contract()
        let mnemonic = try XCTUnwrap(contract.classify.first { $0.expect.secret == "recoveryPhrase" }?.value)
        let key = try XCTUnwrap(contract.classify.first { $0.expect.format == "wif" }?.value)

        WalletGuard.isEnabled = true
        XCTAssertFalse(app.admitCopiedText(mnemonic))
        XCTAssertEqual(shown.last?.body, contract.notices["recoveryPhrase"]); XCTAssertEqual(shown.last?.persistent, false)
        XCTAssertTrue(line.notice?.contains(contract.notices["recoveryPhrase"] ?? "-") ?? false)
        XCTAssertFalse(app.admitCopiedText(key))
        XCTAssertEqual(shown.last?.body, contract.notices["privateKey"])

        let hijack = try XCTUnwrap(contract.scenarios.first { $0.name.hasPrefix("unknown application context") })
        XCTAssertTrue(app.admitCopiedText(hijack.steps[0].text))
        XCTAssertTrue(app.admitCopiedText(hijack.steps[1].text))
        XCTAssertEqual(shown.last?.persistent, true)
        XCTAssertEqual(shown.last?.rows.map(\.value), [hijack.steps[0].text, hijack.steps[1].text])
        XCTAssertEqual(shown.last?.body, "Your copied address was replaced by another address. This is how clipboard malware steals crypto.")

        let reset = try XCTUnwrap(contract.scenarios.first { $0.name.hasPrefix("turning the guard off") })
        var count = shown.count
        XCTAssertTrue(app.admitCopiedText(reset.steps[0].text))
        app.setWalletGuardEnabled(false); app.setWalletGuardEnabled(true)
        XCTAssertTrue(app.admitCopiedText(reset.steps[1].text))
        XCTAssertEqual(shown.count, count, "turning the guard off forgets the last copied address")

        app.setWalletGuardEnabled(false)
        XCTAssertFalse(WalletGuard.isEnabled)
        count = shown.count
        XCTAssertTrue(app.admitCopiedText(mnemonic))
        XCTAssertEqual(shown.count, count)
    }

    func testPersistentWarningIsNotReplacedByANotice() throws {
        let warning = try XCTUnwrap(WalletGuardMessage(WalletGuardVerdict(alert: .hijack(original: "A", replacement: "B"))))
        let lookalike = try XCTUnwrap(WalletGuardMessage(WalletGuardVerdict(alert: .poisoning(address: "C", similar: "D"))))
        let phrase = try XCTUnwrap(WalletGuardMessage(WalletGuardVerdict(save: false, notice: .recoveryPhrase)))
        let key = try XCTUnwrap(WalletGuardMessage(WalletGuardVerdict(save: false, notice: .privateKey)))
        var presentation = WalletGuardPresentation()
        XCTAssertTrue(presentation.receive(phrase)); XCTAssertEqual(presentation.current, phrase)
        XCTAssertTrue(presentation.receive(warning), "a warning replaces a notice")
        XCTAssertFalse(presentation.receive(key), "a notice waits behind an undismissed warning")
        XCTAssertEqual(presentation.current, warning); XCTAssertEqual(presentation.queued, key)
        XCTAssertTrue(presentation.receive(lookalike), "a newer warning is shown")
        XCTAssertEqual(presentation.dismiss(), key, "the waiting notice follows the dismissal")
        XCTAssertNil(presentation.current); XCTAssertNil(presentation.queued)
        XCTAssertTrue(presentation.receive(warning)); XCTAssertFalse(presentation.receive(phrase))
        presentation.clear()
        XCTAssertNil(presentation.current); XCTAssertNil(presentation.queued)
        XCTAssertNil(presentation.dismiss())
    }

    func testEveryWalletGuardStringHasATurkishTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/Tendedero/Resources")
        let english = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings")) as? [String: String])
        let turkish = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("tr.lproj/Localizable.strings")) as? [String: String])
        let verdicts: [WalletGuardVerdict] = [
            WalletGuardVerdict(save: false, notice: .recoveryPhrase), WalletGuardVerdict(save: false, notice: .privateKey),
            WalletGuardVerdict(alert: .hijack(original: "A", replacement: "B")), WalletGuardVerdict(alert: .poisoning(address: "A", similar: "B"))]
        for verdict in verdicts {
            let message = try XCTUnwrap(WalletGuardMessage(verdict))
            for key in [message.title, message.body] + message.rows.map(\.label) {
                XCTAssertEqual(english[key], key)
                XCTAssertNotNil(turkish[key], key); XCTAssertNotEqual(turkish[key], key)
            }
        }
        XCTAssertNil(WalletGuardMessage(WalletGuardVerdict()))
    }
}
