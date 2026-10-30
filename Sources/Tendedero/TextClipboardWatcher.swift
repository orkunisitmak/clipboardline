import AppKit
import UniformTypeIdentifiers

@MainActor
final class TextClipboardWatcher {
    static let maximumDataBytes = 1024 * 1024
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "textClipboardEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "textClipboardEnabled") }
    }
    private let source: any ClipboardSource
    private let onText: (String) -> Void
    private let onLink: ((URL) -> Void)?
    private let capturesText: () -> Bool
    private let capturesLinks: () -> Bool
    /// Wallet Guard runs on decoded text before any history, link or index
    /// path. Returning false withholds the copy from every destination.
    private let admits: (String) -> Bool
    private var timer: Timer?
    private var lastCount: Int?

    convenience init(onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
                     capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false },
                     admits: @escaping (String) -> Bool = { _ in true }) {
        self.init(source: SystemClipboardSource(), onText: onText, onLink: onLink, capturesText: capturesText, capturesLinks: capturesLinks, admits: admits)
    }
    init(source: any ClipboardSource, onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
         capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false },
         admits: @escaping (String) -> Bool = { _ in true }) {
        self.source = source; self.onText = onText; self.onLink = onLink; self.capturesText = capturesText; self.capturesLinks = capturesLinks
        self.admits = admits
    }
    /// Enabling a source starts with the next copy, never the existing board.
    func skipCurrent() { lastCount = source.changeCount }
    func start() {
        guard timer == nil else { return }
        lastCount = source.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; lastCount = nil }
    func check() {
        guard timer != nil else { return }
        guard capturesText() || capturesLinks() else { return }
        let count = source.changeCount
        guard count != lastCount else { return }; lastCount = count
        guard count != ClipboardWatcher.ownChangeCount else { return }
        let items = source.itemTypes
        guard !items.contains(where: { types in
            !ClipboardWatcher.privateTypes.isDisjoint(with: types) || types.contains(.fileURL)
                || types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true })
        }), source.changeCount == count else { return }
        for (index, types) in items.enumerated() where types.contains(.string) || (capturesLinks() && types.contains(.URL)) {
            guard source.changeCount == count else { return }
            let data = source.data(forType: types.contains(.string) ? .string : .URL, at: index)
            guard source.changeCount == count else { return }
            guard let data,
                  !data.isEmpty, data.count <= Self.maximumDataBytes,
                  String(data: data, encoding: .utf8) != nil else { continue }
            // Decode the validated UTF-8 literally; Foundation's encoding initializer
            // consumes a leading BOM, which changes an otherwise valid copy.
            let text = String(decoding: data, as: UTF8.self)
            guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { continue }
            guard source.changeCount == count, admits(text) else { return }
            if capturesLinks(), let onLink, let url = LinkIdentity.standalone(text) { onLink(url) }
            else if capturesText() { onText(text) }
            return
        }
    }
}
