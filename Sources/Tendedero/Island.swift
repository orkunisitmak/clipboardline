import AppKit
import SwiftUI

/// Shelves can hang as the classic three rows or as one island grown from
/// the notch, with every copy on a single rope and a filter above it.
enum ShelfLayoutMode: String, CaseIterable {
    case classic, island
    var title: String { self == .classic ? L("Classic shelves") : L("Island") }
}

/// Black melts into a MacBook's camera notch; glass shows the desktop through.
enum IslandSurface: String, CaseIterable {
    case black, glass
    var title: String { self == .black ? L("Black") : L("Glass") }
}

/// The hardware notch the island grows from. Without one it grows from a
/// notch-sized pill that fades in and out.
struct IslandNotch: Equatable {
    var size = CGSize(width: 190, height: 32)
    var hardware = false

    @MainActor static func of(_ screen: NSScreen?) -> IslandNotch {
        guard let screen else { return IslandNotch() }
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return IslandNotch(size: CGSize(width: 190, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY)), hardware: false)
        }
        return IslandNotch(size: CGSize(width: max(120, screen.frame.width - left.width - right.width), height: top), hardware: true)
    }
}

/// One card on the island's rope, newest first across every kind.
struct IslandEntry: Identifiable, Equatable {
    let id: UUID
    let shelf: Shelf
    let date: Date
}

enum Island {
    static let maximumWidth: CGFloat = 1120
    static let openRadius: CGFloat = 30
    static let shoulder: CGFloat = 12
    static func height(notch: IslandNotch) -> CGFloat { notch.size.height + Layout.panelHeight + 10 }
    /// The Dynamic Island's own feel: a soft overshoot out, critically damped back.
    static let opening = Animation.spring(response: 0.5, dampingFraction: 0.72)
    static let closing = Animation.spring(response: 0.38, dampingFraction: 1)
    static let openDuration: TimeInterval = 0.5, closeDuration: TimeInterval = 0.42
    static let hitID = UUID()
}

/// The island outline: rounded bottom corners and concave shoulders that
/// melt into the top edge of the screen, like the hardware notch.
struct IslandShape: Shape {
    var radius: CGFloat
    var shoulder: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4), r = min(radius, rect.height / 2, (rect.width - 2 * s) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// One of thirty hangers (contracts/hangers.json), chosen by the card's ID so
/// each card keeps its own across launches.
struct Hanger: Equatable {
    let index: Int, size: Double, lean: Double

    init(seed: UUID) {
        // FNV-1a over the UTF-16 ID string, the same as windows/lib/hangers.cjs.
        var hash: UInt32 = 2166136261
        for unit in seed.uuidString.utf16 { hash ^= UInt32(unit); hash = hash &* 16777619 }
        index = Int(hash % UInt32(HangerCatalog.svgs.count))
        size = 0.82 + Double((hash >> 8) & 255) / 255 * 0.4
        lean = (Double((hash >> 16) & 255) / 255 - 0.5) * 14
    }

    @MainActor private static var images = [Int: NSImage]()
    @MainActor static func image(_ index: Int) -> NSImage {
        if let image = images[index] { return image }
        let image = NSImage(data: Data(HangerCatalog.svgs[index].utf8)) ?? NSImage()
        images[index] = image
        return image
    }
}

private struct UsesHangersKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var usesHangers: Bool {
        get { self[UsesHangersKey.self] }
        set { self[UsesHangersKey.self] = newValue }
    }
}

/// Takes the metal clip's place and footprint; the 40-point drawing overflows
/// it, pivoting on the rope groove so the rope always runs through the clip.
struct HangerView: View {
    let seed: UUID
    var body: some View {
        let hanger = Hanger(seed: seed), anchor = UnitPoint(x: 0.5, y: 12.0 / 40)
        Color.clear.frame(width: 9, height: 26)
            .overlay(alignment: .top) {
                Image(nsImage: Hanger.image(hanger.index))
                    .resizable().frame(width: 40, height: 40)
                    .scaleEffect(hanger.size, anchor: anchor)
                    .rotationEffect(.degrees(hanger.lean), anchor: anchor)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1.5)
                    .offset(y: Layout.pinAbove - 12)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

struct IslandView: View {
    @ObservedObject var line: Line
    @ObservedObject private var texts: TextHistory
    @ObservedObject private var links: LinkHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(line: Line) { self.line = line; texts = line.texts; links = line.links }

    var body: some View {
        GeometryReader { geo in
            let notch = line.islandNotch, open = line.islandExpanded
            let openWidth = min(Island.maximumWidth, geo.size.width - 32)
            let width = (open ? openWidth : notch.size.width) + 2 * Island.shoulder
            let height = open ? Island.height(notch: notch) : notch.size.height
            ZStack(alignment: .top) {
                surface(open: open)
                    .frame(width: width, height: height)
                content(width: openWidth, notch: notch)
                    .frame(width: openWidth, height: Island.height(notch: notch), alignment: .top)
                    .scaleEffect(open ? 1 : 0.94, anchor: .top)
                    .blur(radius: open ? 0 : 8)
                    .opacity(open ? 1 : 0)
                    // Content arrives late on the way out of the notch and leaves first on the way back.
                    .animation(open ? .easeOut(duration: 0.3).delay(reduceMotion ? 0 : 0.2) : .easeIn(duration: 0.12), value: open)
                    .frame(width: width, height: height, alignment: .top)
                    .clipShape(IslandShape(radius: open ? Island.openRadius : 10, shoulder: Island.shoulder))
            }
            .frame(width: width, height: height)
            .animation(reduceMotion ? nil : (open ? Island.opening : Island.closing), value: open)
            // Without a hardware notch the island is born from nothing.
            .opacity(notch.hardware || open ? 1 : 0)
            .animation(open ? .easeOut(duration: 0.08) : .easeIn(duration: 0.12).delay(reduceMotion ? 0 : 0.3), value: open)
            .background(GeometryReader { g in
                Color.clear.preference(key: HitRectsKey.self, value: open ? [Island.hitID: g.frame(in: .global)] : [:])
            })
            .frame(maxWidth: .infinity, alignment: .top)
            .onAppear { line.setIslandViewportWidth(openWidth) }
            .onChange(of: openWidth) { _, value in line.setIslandViewportWidth(value) }
        }
        .onPreferenceChange(HitRectsKey.self) { line.hitRects = $0; line.shelfHitGeometryUpdateCount += 1 }
    }

    @ViewBuilder private func surface(open: Bool) -> some View {
        let shape = IslandShape(radius: open ? Island.openRadius : 10, shoulder: Island.shoulder)
        if line.islandSurface == .glass {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.28))
                // Small, it is still the notch: dark glass turns clear as it opens.
                shape.fill(Color.black).opacity(open ? 0 : 1)
                    .animation(open ? .easeOut(duration: 0.35).delay(0.1) : .easeIn(duration: 0.2), value: open)
                shape.stroke(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .environment(\.colorScheme, .dark)
        } else {
            shape.fill(Color.black).shadow(color: .black.opacity(open ? 0.4 : 0), radius: 24, y: 12)
        }
    }

    private func content(width: CGFloat, notch: IslandNotch) -> some View {
        let entries = line.islandEntries
        let range = Layout.visibleRange(count: entries.count, width: width, offset: line.islandScroll)
        let visible = range.map { (index: $0, entry: entries[$0]) }
        let motion = line.rope(.images)
        return VStack(spacing: 0) {
            Color.clear.frame(height: notch.size.height)
            ZStack(alignment: .topLeading) {
                Rope(width: width, motion: motion)
                if entries.isEmpty {
                    Text(line.islandFilter == nil ? L("Copy something and it will hang here") : L("No matching items"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .position(x: width / 2, y: 95)
                }
                ForEach(visible, id: \.entry.id) { index, entry in
                    let x = Layout.x(index: index, scrollOffset: line.islandScroll)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    card(entry, x: x)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                        .hung(on: motion, x: x)
                }
                IslandHeader(line: line).frame(width: width).padding(.top, 4)
                if let shelf = line.searchEditingShelf, line.isShelfSearchActive {
                    // The same search panel as the classic rows, floating over the rope.
                    ShelfSearchBar(line: line, shelf: shelf).id(shelf)
                        .frame(width: max(0, min(560, width - 32)))
                        .position(x: width / 2, y: Layout.panelHeight / 2 + 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: line.searchEditingShelf)
            .frame(width: width, height: Layout.panelHeight)
            .clipped()
        }
        .environment(\.usesHangers, true)
        .environment(\.colorScheme, .dark)
        .onChange(of: entries.filter { $0.shelf != .images || line.isLanded($0.id) }.map(\.id)) { old, new in
            motion.react(from: old, to: new) { Layout.x(index: $0, scrollOffset: line.islandScroll) }
        }
        .onChange(of: visible.map(\.entry.id)) { _, _ in requestVisible(visible.map(\.entry)) }
        .onAppear { requestVisible(visible.map(\.entry)) }
    }

    @ViewBuilder private func card(_ entry: IslandEntry, x: CGFloat) -> some View {
        switch entry.shelf {
        case .images:
            if let item = line.displayItems.first(where: { $0.id == entry.id }) {
                PeggedView(item: item, line: line, quickNumber: nil, hangX: x)
            }
        case .texts:
            if let value = texts.displayEntries.first(where: { $0.id == entry.id }) {
                TextCard(entry: value, line: line, texts: texts, renderState: ShelfRenderState(line: line, shelf: .texts), quickNumber: nil)
            }
        case .links:
            if let value = links.displayEntries.first(where: { $0.id == entry.id }) {
                LinkCard(entry: value, line: line, links: links, renderState: ShelfRenderState(line: line, shelf: .links), quickNumber: nil)
            }
        }
    }

    /// Thumbnails and link metadata load only for the cards actually on the rope.
    private func requestVisible(_ entries: [IslandEntry]) {
        line.refreshIslandThumbnails(entries.filter { $0.shelf == .images }.map(\.id))
        let linkIDs = Set(entries.filter { $0.shelf == .links }.map(\.id))
        let records = links.displayEntries.filter { linkIDs.contains($0.id) }
        links.thumbnails.request(records.compactMap { $0.thumbnailPath.map { URL(fileURLWithPath: $0) } }, pixels: 320)
        line.onLinkItemsVisible?(records.map(\.id))
    }
}

/// The filter capsule: every kind, or one at a time.
private struct IslandHeader: View {
    @ObservedObject var line: Line
    var body: some View {
        HStack(spacing: 6) {
            if line.isShelfSearchActive, line.searchEditingShelf == nil {
                // An open search stays visible as its phrase and result count; click to edit it.
                ShelfSearchSummary(line: line, shelf: line.activeShelf).frame(maxWidth: 260).fixedSize(horizontal: false, vertical: true)
            } else {
                iconButton("magnifyingglass", L("Search shelves")) { line.beginShelfSearch() }.disabled(line.shelfSearch == nil)
            }
            Spacer()
            HStack(spacing: 2) {
                filter(nil, L("All"), nil)
                ForEach(Shelf.allCases, id: \.self) { shelf in filter(shelf, shelf.title, shelf.icon) }
            }
            .padding(3)
            .background(Color.white.opacity(0.08), in: Capsule())
            Spacer()
            iconButton("command", L("Actions")) { line.onCommandsRequested?() }
            iconButton("square.grid.2x2", L("Library…")) { line.onLibraryRequested?() }
            iconButton("gearshape", L("Settings…")) { line.onSettingsRequested?() }
        }
        .padding(.horizontal, 16)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func filter(_ shelf: Shelf?, _ title: String, _ icon: String?) -> some View {
        let on = line.islandFilter == shelf
        return Button { line.setIslandFilter(shelf) } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(title)
                Text("\(line.islandCount(shelf))").foregroundStyle(.white.opacity(0.4)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? Color.white.opacity(0.16) : .clear, in: Capsule())
            .foregroundStyle(on ? .white : .white.opacity(0.65))
            .contentShape(Capsule())
        }
        .accessibilityAddTraits(on ? .isSelected : [])
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 26, height: 22).contentShape(Rectangle()) }
            .foregroundStyle(.white.opacity(0.7)).help(title).accessibilityLabel(title)
    }
}
