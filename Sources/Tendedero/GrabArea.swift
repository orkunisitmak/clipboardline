import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let isRecording = item.isRecording
        view.url = item.url
        view.dragImage = item.thumb
        view.appCopy = item.managedCopy
        view.selectionMode = line.selecting
        view.payloadProvider = { line.dragItems(id) }
        view.onDeleteItems = { dragged in
            let images = dragged.compactMap { drag in line.items.first { $0.id == drag.id && $0.url == drag.sourceURL } }
            let snapshot = Line.TrashSelection(images: images, appCopies: images.filter { line.historyFiles.isAppCopy($0.url) }.count)
            line.trashSelection(snapshot, confirmed: true)
        }
        view.onPin = { line.select(id); line.focusShelf(.images); line.pinFromUI(id) }
        view.onClick = { flags in
            line.finishShelfSearchEditing(.images, selectFirst: false)
            if line.selecting || flags.contains(.command) || flags.contains(.shift) {
                line.focusShelf(.images, requestFocus: false)
                line.select(id, toggle: flags.contains(.command), extending: flags.contains(.shift))
                line.startSelection()
            } else {
                line.focusShelf(.images, requestFocus: false); line.select(id)
                line.copyAction(id); line.onFocusRequested?()
            }
        }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discardAction(id) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in
            if pressed { line.focusShelf(.images, requestFocus: false) }
            line.pressedID = pressed ? id : nil
        }
        view.menuProvider = {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(item.pinned ? L("Unpin") : L("Pin favorite")) { line.pinFromUI(id) })
            menu.addItem(ClosureMenuItem(L("Name and pin…")) { line.onNameAndPinRequested?(id) })
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copyAction(id) })
            let hasUploaded = item.uploadedURL != nil
            menu.addItem(ClosureMenuItem(hasUploaded ? L("Copy public link") : L("Upload to R2")) { line.upload(id) })
            if hasUploaded {
                menu.addItem(ClosureMenuItem(L("Upload again to R2")) { line.upload(id, forceReupload: true) })
            }
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if !isRecording {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discardAction(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discardAction(id) })

            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var dragImage: NSImage?
    var appCopy = false
    var selectionMode = false
    var allowsMove = true
    var usesCornerActions = true
    var selectsOnMouseDown = false
    var operationMask: NSDragOperation?
    var payloadProvider: (() -> [ShelfDragItem])?
    var onDeleteItems: (([ShelfDragItem]) -> Void)?
    private(set) var dragSnapshot: [ShelfDragItem] = []
    var onPin: () -> Void = {}
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var downModifiers: NSEvent.ModifierFlags = []
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false
    private var handledClick = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    private func isInPin(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        return NSRect(x: bounds.width - Self.crossHitSize, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
            width: Self.crossHitSize, height: Self.crossHitSize).contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if usesCornerActions && isInPin(event) { downPoint = nil; onPin(); return }
        if usesCornerActions && isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downModifiers = event.modifierFlags
        handledClick = selectsOnMouseDown || !event.modifierFlags.intersection([.command, .shift]).isEmpty
        if handledClick { onClick(event.modifierFlags) }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        if selectionMode || handledClick { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        dragSnapshot = payloadProvider?() ?? url.map { [ShelfDragItem(id: UUID(), sourceURL: $0, writer: $0 as NSURL, image: dragImage)] } ?? []
        guard !dragSnapshot.isEmpty else { startedDrag = false; return }
        let items = draggingItems(for: dragSnapshot)
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && !handledClick && event.clickCount == 1 { onClick(downModifiers) }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        // The menu runs until it closes, and the line stays down meanwhile.
        GrabView.isShowingMenu = true
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        GrabView.isShowingMenu = false
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if let operationMask { return operationMask }
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        if context == .withinApplication { return .copy }
        if dragSnapshot.count > 1 { return [.copy, .delete] }
        return appCopy ? (allowsMove ? [.copy, .move, .delete] : [.copy, .delete]) : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            if let onDeleteItems { onDeleteItems(dragSnapshot) } else { onTrash() }
            dragSnapshot.removeAll()
            onDragEnd()
            return
        }
        dragSnapshot.removeAll()
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    func draggingItems(for values: [ShelfDragItem]) -> [NSDraggingItem] {
        values.enumerated().map { index, value in
            let item = NSDraggingItem(pasteboardWriter: value.writer)
            item.setDraggingFrame(imageFrame().offsetBy(dx: CGFloat(min(index, 5) * 5), dy: CGFloat(-min(index, 5) * 5)),
                contents: value.image ?? dragImage ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            return item
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
