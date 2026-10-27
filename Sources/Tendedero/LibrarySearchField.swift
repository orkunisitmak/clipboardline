import AppKit
import SwiftUI

/// Search uses the native field editor so Escape hands focus to the collection
/// before the next key event, without a delayed SwiftUI FocusState update.
@MainActor final class LibrarySearchTextField: NSSearchField, NSSearchFieldDelegate {
    private weak var model: LibraryModel?
    var onWillResignSearchFocus: (() -> Void)?
    init(model: LibraryModel) {
        self.model = model
        super.init(frame: .zero)
        isBezeled = true; bezelStyle = .roundedBezel
        sendsSearchStringImmediately = true; sendsWholeSearchString = false
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        font = .systemFont(ofSize: 13); placeholderString = L("Search this view")
        setAccessibilityLabel(L("Search this view")); delegate = self
        stringValue = model.search
        model.onSearchFocus = { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self); self.selectText(nil)
        }
        model.onSearchEscape = { [weak self] in self?.leaveSearch() ?? false }
        model.onSearchNavigation = { [weak self] event in self?.navigateToResults(event) ?? false }
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ notification: Notification) { if model?.search != stringValue { model?.search = stringValue } }
    private func leaveSearch() -> Bool {
        guard let window else { return false }
        let editor = currentEditor()
        guard window.firstResponder === self || (editor != nil && window.firstResponder === editor) else { return false }
        guard (editor as? NSTextView)?.hasMarkedText() != true else { return false }
        onWillResignSearchFocus?()
        guard model?.focusContent() == true else { return true }
        if window.firstResponder === self || (editor != nil && window.firstResponder === editor) { window.makeFirstResponder(nil) }
        return true
    }
    private func navigateToResults(_ event: NSEvent) -> Bool {
        guard [36, 76, 125].contains(Int(event.keyCode)),
              event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty else { return false }
        return leaveSearch()
    }
}

struct LibrarySearchInput: NSViewRepresentable {
    @ObservedObject var model: LibraryModel
    func makeNSView(context: Context) -> LibrarySearchTextField { LibrarySearchTextField(model: model) }
    func updateNSView(_ view: LibrarySearchTextField, context: Context) {
        if view.stringValue != model.search { view.stringValue = model.search }
    }
}
