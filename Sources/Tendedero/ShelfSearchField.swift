import AppKit
import SwiftUI

/// A native field editor keeps text input out of the shelf's browsing router.
@MainActor final class ShelfSearchTextField: NSTextField, NSTextFieldDelegate {
    private weak var line: Line?
    let shelf: Shelf
    private var focusedRequest = -1

    init(line: Line, shelf: Shelf) {
        self.line = line; self.shelf = shelf
        super.init(frame: .zero)
        font = .systemFont(ofSize: 20)
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        isBordered = false; isBezeled = false; drawsBackground = false
        focusRingType = .none; textColor = .labelColor
        cell?.isScrollable = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholderString = L("Search visible shelves…")
        setAccessibilityLabel(placeholderString ?? L("Search shelves"))
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { line?.shelfSearchBeganEditing(shelf) }
        return accepted
    }
    func prepareForMouseEditing() { line?.beginShelfSearch(shelf) }

    func synchronize() {
        guard let line else { return }
        let query = line.shelfSearchQuery
        if stringValue != query { stringValue = query }
        let request = line.searchFocusRequests[shelf, default: 0]
        if line.searchEditingShelf == shelf, focusedRequest != request, window != nil {
            DispatchQueue.main.async { [weak self, weak line] in
                guard let self, let line, line.searchEditingShelf == self.shelf,
                      self.focusedRequest != request,
                      line.searchFocusRequests[self.shelf, default: 0] == request,
                      let window = self.window else { return }
                // Several representable updates can queue before AppKit starts
                // editing. Do not restart an editor acquired by an earlier one.
                let success = self.ownsEditor || window.makeFirstResponder(self)
                if success, self.ownsEditor {
                    self.focusedRequest = request
                    // selectText restarts AppKit's field editor and emits an end-edit
                    // notification, which would clear the requested shelf focus.
                    if let editor = self.currentEditor() as? NSTextView {
                        editor.setSelectedRange(NSRange(location: 0, length: (self.stringValue as NSString).length))
                        (window as? LinePanel)?.deliverPendingSearchKeys(for: ShelfSearchFocus(shelf: self.shelf, request: request), to: editor)
                    }
                }
            }
        } else if line.searchEditingShelf != shelf, ownsEditor { window?.makeFirstResponder(nil) }
    }
    private var ownsEditor: Bool {
        window?.firstResponder === self || (currentEditor() != nil && window?.firstResponder === currentEditor())
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        line?.shelfSearchBeganEditing(shelf)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        // AppKit may finish a child editor while the row's controls move and
        // SwiftUI mounts the newly requested editor. Keep that pending intent.
        if let line, line.searchEditingShelf == shelf,
           line.searchFocusRequests[shelf, default: 0] != focusedRequest { return }
        line?.finishShelfSearchEditing(shelf, selectFirst: false)
    }
    func controlTextDidChange(_ notification: Notification) { line?.updateShelfSearch(stringValue, for: shelf) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            line?.finishShelfSearchEditing(shelf); window?.makeFirstResponder(nil); return true
        case #selector(NSResponder.cancelOperation(_:)):
            _ = line?.closeShelfSearch(shelf); window?.makeFirstResponder(nil); return true
        case #selector(NSResponder.insertTab(_:)):
            line?.finishShelfSearchEditing(shelf, selectFirst: false)
            window?.makeFirstResponder(nil); line?.switchShelf(); return true
        default: return false
        }
    }
}

struct ShelfSearchInput: NSViewRepresentable {
    @ObservedObject var line: Line
    let shelf: Shelf
    func makeNSView(context: Context) -> ShelfSearchTextField { ShelfSearchTextField(line: line, shelf: shelf) }
    func updateNSView(_ view: ShelfSearchTextField, context: Context) { view.synchronize() }
}

struct ShelfSearchBar: View {
    @ObservedObject var line: Line
    let shelf: Shelf
    private var count: Int { line.shelfSearchResultCount }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    scopeBadges(compact: false).fixedSize()
                    scopeBadges(compact: true).fixedSize()
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { line.onCommandsRequested?() } label: {
                    Label(L("Actions"), systemImage: "command").font(.system(size: 10, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Actions") + " · " + line.keyboardBindings.title(.commandPalette))
                    .accessibilityIdentifier("search-actions")
                if line.shelfSearchIsSearching {
                    ProgressView().controlSize(.small).frame(width: 14)
                } else {
                    Text("\(count)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.055), in: Capsule())
                        .accessibilityLabel(String(format: L("%d items"), count))
                }
                Button { _ = line.closeShelfSearch(shelf) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Close")).accessibilityLabel(L("Close"))
            }
            .padding(.horizontal, 18).padding(.top, 12)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                ShelfSearchInput(line: line, shelf: shelf).frame(minWidth: 40, maxWidth: .infinity).frame(height: 30)
                if !line.shelfSearchQuery.isEmpty {
                    Button {
                        line.updateShelfSearch("", for: shelf); line.beginShelfSearch(shelf)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(.tertiary).frame(width: 22, height: 28)
                    }.buttonStyle(.plain).help(L("Clear search")).accessibilityLabel(L("Clear search"))
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
            Divider().opacity(0.45)
            HStack(spacing: 6) {
                keyHint("↵"); Text(L("Browse results"))
                Spacer(minLength: 12)
                keyHint("esc"); Text(L("Close"))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
            if let error = line.shelfSearchError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11))
                    .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
            }
        }
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 22, x: 0, y: 8)
        .accessibilityIdentifier("shelf-search-panel")
        .help(line.searchShelves.contains(.images) ? (line.library?.imageSearchStatus.isEmpty == false ? line.library!.imageSearchStatus : L("Search text and OCR")) : L("Search shelves"))
    }
    private func scopeBadges(compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(line.searchShelves, id: \.self) { scope in
                HStack(spacing: 4) {
                    Image(systemName: scope.icon)
                    if !compact { Text(scope.title) }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(line.theme.accent(scope))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(line.theme.accent(scope).opacity(0.12), in: Capsule())
                .accessibilityElement(children: .ignore).accessibilityLabel(scope.title)
            }
        }
    }
    private func keyHint(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .medium, design: .monospaced))
            .frame(minWidth: 18, minHeight: 16)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

/// Keeps an applied query discoverable without leaving an editor over results.
struct ShelfSearchSummary: View {
    @ObservedObject var line: Line
    let shelf: Shelf
    private var query: String { line.shelfSearchQuery }
    var body: some View {
        HStack(spacing: 0) {
            Button { line.beginShelfSearch() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium))
                    Text(query.isEmpty ? L("Search shelves") : query).lineLimit(1).truncationMode(.tail)
                    Text("\(line.shelfSearchResultCount)").monospacedDigit().foregroundStyle(.secondary)
                }.padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(L("Search shelves"))
            Button { _ = line.closeShelfSearch(shelf) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L("Clear search"))
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
            .accessibilityIdentifier("shelf-search-summary")
    }
}
