import SwiftUI

struct TextShelfView: View {
    let line: Line
    @ObservedObject var texts: TextHistory
    let width: CGFloat
    var body: some View {
        TextShelfContents(line: line, texts: texts, width: width, renderState: ShelfRenderState(line: line, shelf: .texts)).equatable()
    }
}

private struct TextShelfContents: View, Equatable {
    let line: Line
    @ObservedObject var texts: TextHistory
    let width: CGFloat
    let renderState: ShelfRenderState
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line === rhs.line && lhs.texts === rhs.texts && lhs.width == rhs.width && lhs.renderState == rhs.renderState
    }
    var body: some View {
        let entries = texts.displayEntries
        let quickNumbers = Dictionary(uniqueKeysWithValues: renderState.quickIDs.enumerated().map { ($0.element, $0.offset + 1) })
        let range = Layout.visibleRange(count: entries.count, width: width, offset: texts.scrollOffset)
        ZStack(alignment: .topLeading) {
            if entries.isEmpty {
                Text(renderState.searchActive ? L("No matching items") : texts.favoritesOnly ? L("No matching items") + " · " + renderState.pinnedHint : L("Texts appear here after you enable Hang copied text"))
                    .font(.system(size: 12)).padding(9).background(.regularMaterial, in: Capsule())
                    .position(x: width / 2, y: 95)
            }
            ForEach(range.map { (index: $0, entry: entries[$0]) }, id: \.entry.id) { index, entry in
                TextCard(entry: entry, line: line, texts: texts, renderState: renderState, quickNumber: quickNumbers[entry.id])
                    .position(x: Layout.x(index: index, scrollOffset: texts.scrollOffset),
                        y: Layout.ropeY(x: Layout.x(index: index, scrollOffset: texts.scrollOffset), width: width) - Layout.pinAbove + 65)
            }
        }
    }
}

private struct TextCard: View {
    let entry: TextHistory.Entry
    let line: Line
    @ObservedObject var texts: TextHistory
    let renderState: ShelfRenderState
    let quickNumber: Int?
    @State private var hovering = false
    private var dragging: Bool { renderState.draggingID == entry.id }
    var body: some View {
        VStack(spacing: -8) {
            Clothespin().zIndex(1)
            VStack(alignment: .leading, spacing: 5) {
                if let title = entry.title, !title.isEmpty {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(String(entry.text.prefix(180))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    Text(String(entry.text.prefix(180))).font(.system(size: 11)).lineLimit(5)
                }
            }
                .frame(width: Layout.cardWidth - 20, height: 78, alignment: .topLeading)
                .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Frame.radius))
                .background(renderState.theme.wash(.texts), in: RoundedRectangle(cornerRadius: Frame.radius))
                .overlay(RoundedRectangle(cornerRadius: Frame.radius).strokeBorder(texts.selectedIDs.contains(entry.id) ? Color.accentColor : .clear, lineWidth: 3))
                .overlay(alignment: .topLeading) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: 20).glassFrame(circle: true).padding(3)
                        .opacity(hovering && !dragging ? 1 : 0).allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) { FavoriteBadge(pinned: entry.pinned, visible: (hovering || texts.focusedID == entry.id) && !dragging) }
                .overlay(TextGrabArea(entry: entry, line: line, texts: texts))
                .overlay(alignment: .bottomLeading) { QuickSelectionBadge(number: quickNumber) }
                .overlay(alignment: .bottom) {
                    if texts.copiedIDs.contains(entry.id) { CopyBadge(title: L("Text copied")) }
                }
                .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
                .opacity(dragging ? 0.45 : 1)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .animation(.easeOut(duration: 0.2), value: texts.copiedIDs.contains(entry.id))
                .onHover { hovering = $0 }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(entry.title ?? String(entry.text.prefix(180)))
        .background(GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [entry.id: g.frame(in: .global)]) })
    }
}

struct TextGrabArea: NSViewRepresentable {
    let entry: TextHistory.Entry
    let line: Line
    let texts: TextHistory
    func makeNSView(context: Context) -> GrabView { let view = GrabView(); configure(view); return view }
    func updateNSView(_ view: GrabView, context: Context) { configure(view) }
    private func configure(_ view: GrabView) {
        let id = entry.id
        view.selectionMode = texts.selecting
        view.appCopy = true; view.allowsMove = false
        view.payloadProvider = { texts.dragItems(id) }
        view.onDeleteItems = { dragged in texts.trash(dragged.map(\.id)) }
        view.onPin = { texts.select(id, width: line.viewportWidth); line.focusShelf(.texts); texts.togglePin(id) }
        view.onClick = { flags in
            if texts.selecting || !flags.intersection([.command, .shift]).isEmpty {
                texts.select(id, toggle: flags.contains(.command), extending: flags.contains(.shift), width: line.viewportWidth)
                line.focusShelf(.texts)
            } else {
                texts.select(id, width: line.viewportWidth); texts.copyAction(id); line.focusShelf(.texts)
            }
        }
        view.onDoubleClick = { line.onTextPreviewRequested?(id) }
        view.onLongPress = { line.onTextPreviewRequested?(id) }
        view.onDiscard = {
            if texts.isRetained(id) { texts.removeFromShelf(id); return }
            line.focusShelf(.texts)
            if !texts.selectedIDs.contains(id) { texts.select(id, width: line.viewportWidth) }
            line.onTrashRequested?()
        }
        view.onPressChange = { pressed in
            if pressed { line.focusShelf(.texts, requestFocus: false) }
            line.pressedID = pressed ? id : nil
        }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = { line.draggingID = nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { texts.copyAction(id) })
            let hasUploaded = entry.uploadedURL != nil
            menu.addItem(ClosureMenuItem(hasUploaded ? L("Copy public link") : L("Upload to R2")) { line.upload(id) })
            if hasUploaded {
                menu.addItem(ClosureMenuItem(L("Upload again to R2")) { line.upload(id, forceReupload: true) })
            }
            menu.addItem(ClosureMenuItem(entry.pinned ? L("Unpin") : L("Pin favorite")) { texts.togglePin(id) })
            menu.addItem(ClosureMenuItem(L("Name and pin…")) { line.onNameAndPinRequested?(id) })
            menu.addItem(ClosureMenuItem(L("Preview")) { line.onTextPreviewRequested?(id) })
            menu.addItem(ClosureMenuItem(L("Move to Trash…")) {
                line.focusShelf(.texts)
                if !texts.selectedIDs.contains(id) { texts.select(id, width: line.viewportWidth) }
                line.onTrashRequested?()
            })
            return menu
        }
    }
}
