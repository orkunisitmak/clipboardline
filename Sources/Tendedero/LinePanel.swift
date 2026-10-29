import AppKit
import QuartzCore
import SwiftUI

protocol ShelfHostingLayoutCounting: AnyObject {
    var shelfLayoutCount: Int { get }
}

/// Keep SwiftUI layout out of the compositor-only reveal animation.
final class ShelfHostingView<Content: View>: NSHostingView<Content>, ShelfHostingLayoutCounting {
    private(set) var shelfLayoutCount = 0
    override func layout() { shelfLayoutCount += 1; super.layout() }
}

private final class ShelfCompositorView: NSView {
    override var isFlipped: Bool { true }
}

struct ShelfSearchFocus: Equatable {
    let shelf: Shelf
    let request: Int
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, takes keyboard focus for browsing, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    private let reduceMotion: () -> Bool
    private var visibilityGeneration = 0
    private let compositor = ShelfCompositorView()
    private let hostedContent: NSView
    private var shelfRevealed = false
    private(set) var isShelfTransitioning = false
    static let shelfAnimationKey = "shelfRevealTranslation"
    var shelfModelOffset: CGFloat { compositor.layer?.sublayerTransform.m42 ?? 0 }
    var shelfPresentationOffset: CGFloat { compositor.layer?.presentation()?.sublayerTransform.m42 ?? shelfModelOffset }
    private var hiddenShelfOffset: CGFloat { islandReveal == nil ? -(contentHeight + 12) : 0 }
    /// Island mode: the panel stays put over the menu bar and the island
    /// morphs out of the notch itself instead of the rows sliding down.
    var islandReveal: ((Bool) -> Void)? {
        didSet {
            level = islandReveal == nil ? .floating : .statusBar
            if !shelfRevealed && !isShelfTransitioning { setShelfOffset(hiddenShelfOffset) }
        }
    }
    var onPlaced: ((NSScreen) -> Void)?
#if STANDALONE_TESTS
    @objc var shelfAnimationLayerForTesting: CALayer? { compositor.layer }
    @objc var shelfHostingLayoutCountForTesting: Int { (hostedContent as? ShelfHostingLayoutCounting)?.shelfLayoutCount ?? 0 }
#endif
    var keyboardFocusAllowed = false
    var onKey: ((NSEvent) -> Bool)?
    var onCommandKey: ((NSEvent) -> Bool)?
    var onBeforeMouseKeyFocus: (() -> Void)?
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    var onScrollLocation: ((NSPoint) -> Void)?
    var contentHeight = Layout.panelHeight {
        didSet {
            // A hidden single row can become three rows before its next reveal.
            if !shelfRevealed && !isShelfTransitioning { setShelfOffset(hiddenShelfOffset) }
        }
    }
    var searchEditorTarget: (() -> ShelfSearchFocus?)?
    private var pendingSearchTarget: ShelfSearchFocus?
    private var pendingSearchKeys = [NSEvent]()

    /// SwiftUI may need one layout turn to mount a newly opened field. Keep
    /// input from that interval in order, and never send it to a later search.
    func deliverPendingSearchKeys(for target: ShelfSearchFocus, to editor: NSTextView) {
        let events = pendingSearchTarget == target ? pendingSearchKeys : []
        pendingSearchKeys.removeAll(); pendingSearchTarget = nil
        for event in events {
            guard searchEditorTarget?() == target, firstResponder === editor else { break }
            editor.interpretKeyEvents([event])
        }
    }

    func routeKey(_ event: NSEvent, isFocused: Bool) -> Bool {
        guard event.type == .keyDown, keyboardFocusAllowed, isFocused else { return false }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty,
           onCommandKey?(event) == true { return true }
        // Search owns the native field editor. Ordinary typing, arrows,
        // Backspace and editing shortcuts must never trigger shelf actions.
        if firstResponder is NSTextView || firstResponder is NSTextField { return false }
        if let target = searchEditorTarget?() {
            if pendingSearchTarget != target { pendingSearchKeys.removeAll(); pendingSearchTarget = target }
            pendingSearchKeys.append(event)
            return true
        }
        pendingSearchKeys.removeAll(); pendingSearchTarget = nil
        return onKey?(event) == true
    }

    override func sendEvent(_ event: NSEvent) {
        if isShelfTransitioning, [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown,
            .otherMouseUp, .otherMouseDragged, .scrollWheel].contains(event.type) { return }
        prepareForMouseKeyFocus(event, isFocused: isKeyWindow)
        if event.type == .leftMouseDown { prepareSearchMouseFocus(at: event.locationInWindow) }
        if routeKey(event, isFocused: isKeyWindow) { return }
        if event.type == .scrollWheel, let onScroll {
            onScrollLocation?(event.locationInWindow)
            onScroll(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return
        }
        super.sendEvent(event)
    }

    /// A still-visible nonactivating shelf can be clicked after the user has
    /// moved to a different external field. Capture before AppKit or a child
    /// view claims key focus; the later Library/copy action is already too late.
    func prepareForMouseKeyFocus(_ event: NSEvent, isFocused: Bool) {
        guard event.type == .leftMouseDown, !isFocused else { return }
        onBeforeMouseKeyFocus?()
    }

    /// New AppKit search fields have interactive child views. Mark the owning
    /// shelf before those children start editing, rather than waiting for the
    /// first text-change notification and losing focus during a SwiftUI update.
    func prepareSearchMouseFocus(at windowPoint: NSPoint) {
        guard let content = contentView else { return }
        let point = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var candidate = content.hitTest(point)
        while let view = candidate {
            if let field = view as? ShelfSearchTextField { field.prepareForMouseEditing(); return }
            candidate = view.superview
        }
    }

    init(content: NSView, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        self.hostedContent = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        compositor.frame = content.frame
        compositor.wantsLayer = true
        compositor.layer?.masksToBounds = true
        compositor.layer?.isGeometryFlipped = true
        content.frame = compositor.bounds
        content.autoresizingMask = [.width, .height]
        compositor.addSubview(content)
        contentView = compositor
        setShelfOffset(hiddenShelfOffset)
    }

    override var canBecomeKey: Bool { keyboardFocusAllowed }
    override var canBecomeMain: Bool { false }

    private func setShelfOffset(_ offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compositor.layer?.sublayerTransform = CATransform3DMakeTranslation(0, offset, 0)
        CATransaction.commit()
    }

    /// Slide the retained layer tree down from above the display. Only the
    /// compositor transform moves: window, hosting bounds and SwiftUI geometry
    /// remain fixed, including on vertically stacked monitors. Reverse from the
    /// current presentation position rather than jumping to an old endpoint.
    func setShelfRevealed(_ on: Bool, animated: Bool = true, completion: (() -> Void)? = nil) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let current = shelfPresentationOffset
        compositor.layer?.removeAnimation(forKey: Self.shelfAnimationKey)
        shelfRevealed = on
        let target: CGFloat = on ? 0 : hiddenShelfOffset
        if let islandReveal { revealIsland(on, animated: animated, generation: generation, morph: islandReveal, completion: completion); return }
        let duration: TimeInterval = animated && !reduceMotion() ? (on ? 0.42 : 0.22) : 0
        isShelfTransitioning = duration > 0 && abs(current - target) > 0.01
        // NSView hit testing uses the unchanged model geometry. Accept pointer
        // actions only once the translated cards reach those coordinates.
        if isShelfTransitioning { ignoresMouseEvents = true }
        alphaValue = 1
        setShelfOffset(target)
        if isShelfTransitioning {
            let animation = CABasicAnimation(keyPath: "sublayerTransform")
            animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, current, 0))
            animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, target, 0))
            animation.duration = duration
            animation.beginTime = compositor.layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
            animation.timingFunction = on
                ? CAMediaTimingFunction(controlPoints: 0.2, 1.12, 0.3, 1)
                : CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            compositor.layer?.add(animation, forKey: Self.shelfAnimationKey)
        }
        let delay = isShelfTransitioning ? duration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.compositor.layer?.removeAnimation(forKey: Self.shelfAnimationKey)
            self.isShelfTransitioning = false
            completion?()
        }
    }

    private func revealIsland(_ on: Bool, animated: Bool, generation: Int, morph: (Bool) -> Void, completion: (() -> Void)?) {
        alphaValue = 1
        setShelfOffset(0)
        let duration = animated && !reduceMotion() ? (on ? Island.openDuration : Island.closeDuration) : 0
        isShelfTransitioning = duration > 0
        if isShelfTransitioning { ignoresMouseEvents = true }
        morph(on)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.isShelfTransitioning = false
            completion?()
        }
    }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let screen = screen ?? LinePanel.screenUnderPointer() else { return }
        onPlaced?(screen)
        // The island hangs from the very top edge, over the menu bar and notch.
        let visible = islandReveal == nil ? screen.visibleFrame : screen.frame
        let target = NSRect(x: visible.minX, y: visible.maxY - contentHeight,
                            width: visible.width, height: contentHeight)
        // Presentation follows placement/capacity in the same turn. Do not
        // force a synchronous SwiftUI draw before that final state is ready.
        if frame != target { setFrame(target, display: false) }
    }
}
