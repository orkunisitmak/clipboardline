import SwiftUI

struct LinkShelfView: View {
    let line: Line
    @ObservedObject var links: LinkHistory
    let width: CGFloat
    var body: some View {
        LinkShelfContents(line: line, links: links, width: width, renderState: ShelfRenderState(line: line, shelf: .links)).equatable()
    }
}

private struct LinkShelfContents: View, Equatable {
    let line: Line
    @ObservedObject var links: LinkHistory
    let width: CGFloat
    let renderState: ShelfRenderState
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line === rhs.line && lhs.links === rhs.links && lhs.width == rhs.width && lhs.renderState == rhs.renderState
    }
    var body: some View {
        let entries = links.displayEntries
        let quickNumbers = Dictionary(uniqueKeysWithValues: renderState.quickIDs.enumerated().map { ($0.element, $0.offset + 1) })
        let range = Layout.visibleRange(count: entries.count, width: width, offset: links.scrollOffset)
        let payload = range.map { VisibleLinkPayload(id: entries[$0].id, thumbnailPath: entries[$0].thumbnailPath) }
        ZStack(alignment: .topLeading) {
            if entries.isEmpty {
                Text(renderState.searchActive ? L("No matching items") : links.favoritesOnly ? L("No matching items") + " · " + renderState.pinnedHint : L("Copied web addresses appear here when link capture is enabled"))
                    .font(.system(size: 12)).padding(9).background(.regularMaterial, in: Capsule()).position(x: width / 2, y: 95)
            }
            ForEach(range.map { (index: $0, entry: entries[$0]) }, id: \.entry.id) { index, entry in
                LinkCard(entry: entry, line: line, links: links, renderState: renderState, quickNumber: quickNumbers[entry.id])
                    .position(x: Layout.x(index: index, scrollOffset: links.scrollOffset),
                        y: Layout.ropeY(x: Layout.x(index: index, scrollOffset: links.scrollOffset), width: width) - Layout.pinAbove + (18 + 112 * Layout.scale) / 2)
            }
        }.onAppear { requestThumbnails(payload) }
            .onChange(of: payload) { _, value in requestThumbnails(value) }
    }
    private func requestThumbnails(_ payload: [VisibleLinkPayload]) {
        links.thumbnails.request(payload.compactMap { $0.thumbnailPath.map { URL(fileURLWithPath: $0) } }, pixels: 320)
        line.onLinkItemsVisible?(payload.map(\.id))
    }
}

private struct LinkCard: View {
    let entry: LibraryRecord
    let line: Line
    @ObservedObject var links: LinkHistory
    let renderState: ShelfRenderState
    let quickNumber: Int?
    @State private var hovering = false
    private var thumbnail: NSImage? { entry.thumbnailPath.flatMap { links.thumbnails.image(for: URL(fileURLWithPath: $0), pixels: 320) } }
    var body: some View {
        VStack(spacing: -8) {
            Clothespin().zIndex(1)
            VStack(alignment: .leading, spacing: 5 * Layout.scale) {
                ZStack {
                    renderState.theme.wash(.links)
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else { Image(systemName: LinkIdentity.youtubeID(entry.linkURL ?? URL(string: "https://invalid.example")!) == nil ? "link" : "play.rectangle").font(.system(size: 24)).foregroundStyle(.secondary) }
                }.frame(width: Layout.cardWidth - 16 * Layout.scale, height: 38 * Layout.scale).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                Text(entry.displayTitle).font(.system(size: 10 * Layout.scale, weight: .semibold)).lineLimit(2).frame(height: 26 * Layout.scale, alignment: .topLeading)
                Text(entry.author ?? entry.linkURL?.host ?? L("Link")).font(.system(size: 9 * Layout.scale)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(8 * Layout.scale).padding(.top, 12 * Layout.scale).frame(width: Layout.cardWidth, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Frame.radius))
                .background(renderState.theme.wash(.links), in: RoundedRectangle(cornerRadius: Frame.radius))
                .overlay(RoundedRectangle(cornerRadius: Frame.radius).strokeBorder(links.selectedIDs.contains(entry.id) ? Color.accentColor : .clear, lineWidth: 3))
                .overlay(alignment: .topLeading) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 20, height: 20).glassFrame(circle: true).padding(3).opacity(hovering ? 1 : 0).allowsHitTesting(false) }
                .overlay(alignment: .topTrailing) { FavoriteBadge(pinned: entry.favorite, visible: hovering || links.focusedID == entry.id) }
                .overlay(LinkGrabArea(entry: entry, line: line, links: links))
                .overlay(alignment: .bottomLeading) { QuickSelectionBadge(number: quickNumber) }
                .overlay(alignment: .bottom) { if links.copiedIDs.contains(entry.id) { CopyBadge(title: L("Link copied")) } }
                .shadow(color: .black.opacity(0.18), radius: hovering ? 14 : 10, y: 5)
                .onHover { hovering = $0 }
        }.accessibilityElement(children: .ignore).accessibilityLabel(entry.displayTitle)
            .background(GeometryReader { geo in Color.clear.preference(key: HitRectsKey.self, value: [entry.id: geo.frame(in: .global)]) })
    }
}

private struct LinkGrabArea: NSViewRepresentable {
    let entry: LibraryRecord
    let line: Line
    let links: LinkHistory
    func makeNSView(context: Context) -> GrabView { let view = GrabView(); configure(view); return view }
    func updateNSView(_ view: GrabView, context: Context) { configure(view) }
    private func configure(_ view: GrabView) {
        let id = entry.id
        view.selectionMode = links.selecting; view.appCopy = true; view.allowsMove = false
        view.payloadProvider = { links.dragItems(id) }
        view.onDeleteItems = { links.trash($0.map(\.id)) }
        view.onPin = { links.select(id, width: line.viewportWidth); line.focusShelf(.links); links.togglePin(id) }
        view.onClick = { flags in
            links.select(id, toggle: flags.contains(.command), extending: flags.contains(.shift), width: line.viewportWidth)
            if !links.selecting && flags.intersection([.command, .shift]).isEmpty { links.copyAction(id) }
            line.focusShelf(.links)
        }
        view.onDoubleClick = { line.onLinkPreviewRequested?(id) }; view.onLongPress = { line.onLinkPreviewRequested?(id) }
        view.onDiscard = { links.removeFromShelf(id) }
        view.onPressChange = { line.pressedID = $0 ? id : nil; if $0 { line.focusShelf(.links, requestFocus: false) } }
        view.onDragStart = { line.draggingID = id }; view.onDragEnd = { line.draggingID = nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { links.copyAction(id) })
            let hasUploaded = entry.uploadedURL != nil
            menu.addItem(ClosureMenuItem(hasUploaded ? L("Copy public link") : L("Upload to R2")) { line.upload(id) })
            if hasUploaded {
                menu.addItem(ClosureMenuItem(L("Upload again to R2")) { line.upload(id, forceReupload: true) })
            }
            menu.addItem(ClosureMenuItem(L("Preview")) { line.onLinkPreviewRequested?(id) })
            menu.addItem(ClosureMenuItem(entry.favorite ? L("Unpin") : L("Pin favorite")) { links.togglePin(id) })
            menu.addItem(ClosureMenuItem(L("Name and pin…")) { line.onNameAndPinRequested?(id) })
            menu.addItem(ClosureMenuItem(L("Open in browser")) { if let url = entry.linkURL { NSWorkspace.shared.open(url) } })
            menu.addItem(ClosureMenuItem(L("Move to Trash…")) { links.select(id, width: line.viewportWidth); line.focusShelf(.links); line.onTrashRequested?() })
            menu.addItem(ClosureMenuItem(L("Library…")) { line.onLibraryRequested?() })
            return menu
        }
    }
}
