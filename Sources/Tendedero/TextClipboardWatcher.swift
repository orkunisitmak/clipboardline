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
    private var timer: Timer?
    private var lastCount: Int?

    convenience init(onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
                     capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false }) {
        self.init(source: SystemClipboardSource(), onText: onText, onLink: onLink, capturesText: capturesText, capturesLinks: capturesLinks)
    }
    init(source: any ClipboardSource, onText: @escaping (String) -> Void, onLink: ((URL) -> Void)? = nil,
         capturesText: @escaping () -> Bool = { true }, capturesLinks: @escaping () -> Bool = { false }) {
        self.source = source; self.onText = onText; self.onLink = onLink; self.capturesText = capturesText; self.capturesLinks = capturesLinks
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
            let preferredType: NSPasteboard.PasteboardType = capturesLinks() && types.contains(.URL) ? .URL : .string
            let representationTypes = preferredType == .URL && types.contains(.string) ? [.URL, .string] : [preferredType]
            for type in representationTypes {
                let data = source.data(forType: type, at: index)
                guard source.changeCount == count else { return }
                guard let data,
                      !data.isEmpty, data.count <= Self.maximumDataBytes,
                      String(data: data, encoding: .utf8) != nil else { continue }
                // Decode the validated UTF-8 literally; Foundation's encoding initializer
                // consumes a leading BOM, which changes an otherwise valid copy.
                let text = String(decoding: data, as: UTF8.self)
                guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { continue }
                guard source.changeCount == count else { return }
                if capturesLinks(), let onLink, let url = LinkIdentity.standalone(text) { onLink(url); return }
                if type == .URL && types.contains(.string) { continue }
                if capturesText() { onText(text) }
                return
            }
        }
    }
}
