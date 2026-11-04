import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures a dragged area of the screen on a global shortcut (⌘9 unless
/// changed), the way dedicated screenshot tools do.
///
/// Every display is frozen first, so open menus and hover states stay exactly
/// as they were, then dimmed. Drag out the area to keep; drag inside it to move
/// it, or its edges to resize it. Arrows, rectangles, ellipses, lines, pen and
/// marker strokes and text can be drawn on it in any palette color. Return,
/// ⌘C or a double click copies it, ⌘S saves it as a PNG file, Esc or a right
/// click cancels. ⌘A takes the whole display and the arrow keys nudge the
/// area (with Shift, ten points).
///
/// Screen capture needs the Screen & System Audio Recording permission; the
/// overlay never appears without it.
@MainActor
final class AreaCapture {
    enum Output: Equatable { case copy, save }

    struct Result {
        let image: CGImage
        /// The captured area in AppKit global screen coordinates.
        let screenRect: CGRect
        let output: Output
        /// The app that was in front before the overlay took the keyboard.
        let previousApplication: NSRunningApplication?
    }

    enum Failure: Error { case noDisplay }

    private var windows: [AreaCaptureWindow] = []
    private var completion: ((Result?) -> Void)?
    private var task: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    private(set) var finished = false

    /// Freezes the screens and shows the overlay. The completion runs once:
    /// with the kept area, or nil when cancelled or when capture failed.
    func start(completion: @escaping (Result?) -> Void) {
        self.completion = completion
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        task = Task { [weak self] in
            do {
                let frozen = try await Self.freezeScreens()
                guard let self, !self.finished, !Task.isCancelled else { return }
                self.present(frozen)
            } catch {
                guard let self, !self.finished else { return }
                log.error("Area capture failed: \(String(describing: error), privacy: .public)")
                self.finish(nil, from: nil)
                if !CGPreflightScreenCaptureAccess() { Self.showPermissionAlert() } else { NSSound.beep() }
            }
        }
    }

    /// Closes the overlay without keeping anything.
    func cancel() { finish(nil, from: nil) }

    // MARK: Freezing the screens

    private static func freezeScreens() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var frozen: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let id = screen.areaCaptureDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frozen.append((screen, image))
        }
        guard !frozen.isEmpty else { throw Failure.noDisplay }
        return frozen
    }

    // MARK: The overlay

    private func present(_ frozen: [(NSScreen, CGImage)]) {
        for (screen, image) in frozen {
            let window = AreaCaptureWindow(screen: screen, image: image)
            window.overlay.onBegin = { [weak self, weak window] in self?.selectionBegan(in: window) }
            window.overlay.onFinish = { [weak self, weak window] output in self?.finish(output, from: window) }
            windows.append(window)
        }
        // A display added or removed under the overlay would leave it covering
        // the wrong area; start again instead.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        for window in windows where window !== key { window.orderFrontRegardless() }
        // The panels take the keyboard without activating the app; activating
        // it as well lets the crosshair cursor show over other apps.
        NSApp.activate(ignoringOtherApps: true)
        key?.makeKeyAndOrderFront(nil)
        if let key { key.makeFirstResponder(key.overlay) }
        NSCursor.crosshair.set()
    }

    private func selectionBegan(in window: AreaCaptureWindow?) {
        for other in windows {
            other.overlay.showsHint = false
            if other !== window { other.overlay.clearSelection() }
        }
    }

    private func finish(_ output: Output?, from window: AreaCaptureWindow?) {
        guard !finished else { return }
        finished = true
        task?.cancel(); task = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        var result: Result?
        if let output, let window, let image = window.overlay.renderedImage(),
           let rect = window.overlay.selectionInScreen() {
            result = Result(image: image, screenRect: rect, output: output, previousApplication: previousApplication)
        }
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        NSCursor.arrow.set()
        // Saving keeps the app in front for its panel and returns afterwards.
        if output != .save || result == nil { previousApplication?.activate(options: []) }
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    // MARK: Permission

    /// True when screens can be captured. Otherwise the request is made every
    /// time: that is what puts the app in the Screen Recording list, and macOS
    /// shows its own prompt the first time. An alert then explains where to
    /// allow it.
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        showPermissionAlert()
        return false
    }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Allow screen recording to capture an area")
        alert.informativeText = String(format: L("Turn on %@ in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen it."), AppIdentity.name)
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openPermissionSettings() }
    }

    // MARK: Files

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes the capture as a temporary app copy, named like a copied
    /// clipboard image so it follows the same history rules: it expires with
    /// unsaved images unless pinned, filed or tagged.
    static func writeAppCopy(_ png: Data, rect: CGRect, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Clipboard \(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        markAsScreenCapture(url, rect: rect)
        return url
    }

    /// Tags the file as macOS tags its own screenshots: where it was taken,
    /// so it can fly from there to the line, and that it is a screen capture.
    static func markAsScreenCapture(_ url: URL, rect: CGRect) {
        guard let main = NSScreen.screens.first else { return }
        // Global points with the origin at the top left of the main display.
        let values: [Double] = [Double(rect.minX), Double(main.frame.maxY - rect.maxY), Double(rect.width), Double(rect.height)]
        let attributes: [(String, Any)] = [
            ("com.apple.metadata:kMDItemScreenCaptureGlobalRect", values),
            ("com.apple.metadata:kMDItemIsScreenCapture", true)
        ]
        for (name, value) in attributes {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { continue }
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                data.withUnsafeBytes { bytes in
                    _ = setxattr(path, name, bytes.baseAddress, data.count, 0, 0)
                }
            }
        }
    }

    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return L("Screenshot") + " " + formatter.string(from: date) + ".png"
    }

    private static let saveFolderKey = "areaCaptureSaveFolder"

    /// Where the previous capture was saved, if that folder still exists.
    static var lastSaveFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: saveFolderKey) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: saveFolderKey) }
    }

    /// The selected pixels of a frozen display with the marks drawn in, at the
    /// display's full resolution. `pixels` has a top-left origin, as
    /// `pixelRect` returns it; marks are in unit coordinates of the display.
    static func render(_ image: CGImage, pixels: CGRect, elements: [ImageMarkupElement]) -> CGImage? {
        guard !elements.isEmpty else { return image.cropping(to: pixels) }
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        func makeContext(in space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        // Keep the display's own colors when they fit an 8-bit RGB context.
        let native = image.colorSpace.flatMap { $0.model == .rgb ? makeContext(in: $0) : nil }
        guard let context = native ?? CGColorSpace(name: CGColorSpace.sRGB).flatMap(makeContext(in:)) else { return nil }
        // The whole display, placed so that the selected pixels fill the context.
        let display = CGRect(x: -pixels.minX, y: pixels.maxY - CGFloat(image.height),
                             width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: display)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ImageMarkupRenderer.draw(elements: elements, in: display)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Geometry

    /// The pixels of a frozen display that a selection covers. The selection
    /// is in view points with the origin at the bottom left; the image has its
    /// origin at the top left. Rounded outwards and kept inside the image.
    nonisolated static func pixelRect(for selection: CGRect, viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let sx = CGFloat(imageWidth) / viewSize.width, sy = CGFloat(imageHeight) / viewSize.height
        let pixels = CGRect(x: selection.minX * sx, y: (viewSize.height - selection.maxY) * sy,
                            width: selection.width * sx, height: selection.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return pixels
    }
}

private extension NSScreen {
    var areaCaptureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// One borderless panel per display, above everything including the menu bar
/// and full screen apps. It takes the keyboard without activating the app.
private final class AreaCaptureWindow: NSPanel {
    let overlay: AreaCaptureView

    init(screen: NSScreen, image: CGImage) {
        overlay = AreaCaptureView(image: image)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = overlay
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys never reach the app's menus while the overlay is up, except
    /// while text is typed: then the field keeps its editing shortcuts and
    /// only ⌘S, which saves the capture, is taken.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if overlay.isEditingText {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags == .command && event.keyCode == 1 else { return super.performKeyEquivalent(with: event) }
        }
        overlay.handleKey(event)
        return true
    }
}

/// Draws nothing itself and lets every click through to the overlay.
private class AreaCapturePassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds the tools, colors and actions. A click between the buttons must not
/// reach the overlay, where it would start a new selection.
private final class AreaCaptureToolbar: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

/// A short white text on a dark rounded badge.
private final class AreaCaptureBadge: AreaCapturePassThroughView {
    private let label = NSTextField(labelWithString: "")
    private let padding = CGSize(width: 7, height: 3)

    init(fontSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 5
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.sizeToFit()
            setFrameSize(CGSize(width: ceil(label.frame.width) + padding.width * 2,
                                height: ceil(label.frame.height) + padding.height * 2))
            label.setFrameOrigin(CGPoint(x: padding.width, y: padding.height))
        }
    }
}

/// Draws the marks over the selection. The view covers only the selection, so
/// marks are clipped to what will be kept; `displayRect` is the whole display
/// in this view's coordinates, the space the marks are stored in.
private final class AreaCaptureAnnotationView: AreaCapturePassThroughView {
    var elements: [ImageMarkupElement] = [] { didSet { needsDisplay = true } }
    var displayRect: CGRect = .zero { didSet { if displayRect != oldValue { needsDisplay = true } } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        ImageMarkupRenderer.draw(elements: elements, in: displayRect)
    }
}

@MainActor
private final class AreaCaptureView: NSView, NSTextFieldDelegate {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }
    private enum Drag {
        case idle
        case create(anchor: CGPoint)
        case move(offset: CGSize)
        case resize(edges: Edges, original: CGRect)
        case mark
    }

    var onBegin: (() -> Void)?
    /// Copy or save the selection; nil cancels the capture.
    var onFinish: ((AreaCapture.Output?) -> Void)?
    var showsHint = true { didSet { updateChrome() } }
    var isEditingText: Bool { textField != nil }

    private let image: CGImage
    private(set) var selection: CGRect? { didSet { updateChrome() } }
    private var drag = Drag.idle
    /// `.select` adjusts the area; every other tool draws inside it.
    private var tool = ImageMarkupTool.select
    private var color = MarkupColor.red
    /// Marks in unit coordinates of the whole display, origin at the bottom left.
    private var elements: [ImageMarkupElement] = []
    private var drawing: ImageMarkupElement?
    private var textField: NSTextField?

    private let canvas = AreaCapturePassThroughView()
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let dashLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let annotations = AreaCaptureAnnotationView()
    private let sizeBadge = AreaCaptureBadge(fontSize: 11)
    private let hintBadge = AreaCaptureBadge(fontSize: 13)
    private let toolbar = AreaCaptureToolbar()
    private let toolsBar = AreaCaptureToolbar()
    private var toolButtons: [NSButton] = []
    private var swatchButtons: [NSButton] = []
    private var undoButton: NSButton?
    private static let edgeTolerance: CGFloat = 6
    private static let margin: CGFloat = 8
    /// Sizes in points on screen; the capture keeps them at its own resolution.
    private static let strokePoints: CGFloat = 3
    private static let markerPoints: CGFloat = 14
    private static let fontPoints: CGFloat = 20

    /// The order of the tool bar, with the key that picks each tool. The keys
    /// match the image markup defaults.
    private static let tools: [(tool: ImageMarkupTool, symbol: String, key: UInt16, letter: String)] = [
        (.select, "crop", 9, "V"), (.arrow, "arrow.up.right", 0, "A"), (.rectangle, "rectangle", 15, "R"),
        (.ellipse, "circle", 31, "O"), (.line, "line.diagonal", 2, "D"), (.pen, "pencil.tip", 11, "B"),
        (.marker, "highlighter", 4, "H"), (.text, "textformat", 17, "T")
    ]

    private static func title(of tool: ImageMarkupTool) -> String {
        switch tool {
        case .select: return L("Adjust area")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .line: return L("Line")
        case .pen: return L("Pen")
        case .marker: return L("Marker")
        case .text: return L("Text annotation")
        }
    }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        canvas.wantsLayer = true
        addSubview(canvas)
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        dimLayer.fillRule = .evenOdd
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        outlineLayer.lineWidth = 1
        dashLayer.fillColor = nil
        dashLayer.strokeColor = NSColor.white.cgColor
        dashLayer.lineWidth = 1
        dashLayer.lineDashPattern = [5, 3]
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        handlesLayer.lineWidth = 1
        for sublayer in [imageLayer, dimLayer, outlineLayer, dashLayer, handlesLayer] { canvas.layer?.addSublayer(sublayer) }

        annotations.isHidden = true
        addSubview(annotations)
        sizeBadge.isHidden = true
        addSubview(sizeBadge)
        hintBadge.text = L("Drag to capture an area. Esc cancels.")
        addSubview(hintBadge)

        // Bottom bar: colors, undo and the ways out.
        swatchButtons = MarkupColor.palette.indices.map { index in
            let button = NSButton(image: Self.swatchImage(MarkupColor.palette[index], selected: false),
                                  target: self, action: #selector(chooseColor(_:)))
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.tag = index
            button.setAccessibilityLabel(L("Color") + " \(index + 1)")
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }
        let undo = iconButton("arrow.uturn.backward", L("Undo") + " (⌘Z)", action: #selector(undoMark), tag: 0)
        undoButton = undo
        let swatches = NSStackView(views: swatchButtons)
        swatches.orientation = .horizontal
        swatches.spacing = 1
        let actions: [NSView] = [
            swatches, undo,
            button(L("Copy"), symbol: "doc.on.doc", tip: "↩ / ⌘C", action: #selector(copySelection)),
            button(L("Save…"), symbol: "square.and.arrow.down", tip: "⌘S", action: #selector(saveSelection)),
            iconButton("xmark", L("Cancel") + " (Esc)", action: #selector(cancelCapture), tag: 0)
        ]
        install(actions, in: toolbar, orientation: .horizontal)

        // Side bar: the drawing tools.
        toolButtons = Self.tools.indices.map { index in
            let entry = Self.tools[index]
            return iconButton(entry.symbol, Self.title(of: entry.tool) + " (\(entry.letter))", action: #selector(chooseTool(_:)), tag: index)
        }
        install(toolButtons, in: toolsBar, orientation: .vertical)
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func install(_ views: [NSView], in bar: AreaCaptureToolbar, orientation: NSUserInterfaceLayoutOrientation) {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 9
        bar.layer?.masksToBounds = true
        bar.addSubview(stack)
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        bar.frame = CGRect(origin: .zero, size: size)
        bar.isHidden = true
        addSubview(bar)
    }

    private func button(_ title: String, symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let button = NSButton(title: title, image: image, target: self, action: action)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.toolTip = title + " (" + tip + ")"
        return button
    }

    private func iconButton(_ symbol: String, _ label: String, action: Selector, tag: Int) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.contentTintColor = .white
        button.tag = tag
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private static func swatchImage(_ color: MarkupColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            color.nsColor.setFill(); dot.fill()
            NSColor.white.withAlphaComponent(0.55).setStroke(); dot.lineWidth = 1; dot.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                NSColor.white.setStroke(); ring.stroke()
            }
            return true
        }
    }

    /// Shows the current tool and color, and whether there is a mark to undo.
    private func updateControls() {
        for (index, button) in toolButtons.enumerated() {
            let active = Self.tools[index].tool == tool
            button.layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.28).cgColor : nil
            button.setAccessibilityValue(active ? "1" : "0")
        }
        for (index, button) in swatchButtons.enumerated() {
            button.image = Self.swatchImage(MarkupColor.palette[index], selected: MarkupColor.palette[index] == color)
        }
        undoButton?.isEnabled = !elements.isEmpty
        undoButton?.alphaValue = elements.isEmpty ? 0.4 : 1
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCanvas()
    }

    override func layout() {
        super.layout()
        layoutCanvas()
    }

    private func layoutCanvas() {
        canvas.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for sublayer in [imageLayer, dimLayer, outlineLayer, dashLayer, handlesLayer] { sublayer.frame = bounds }
        CATransaction.commit()
        updateChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Selection

    func clearSelection() {
        discardText()
        drag = .idle
        drawing = nil
        elements.removeAll()
        selection = nil
        refreshAnnotations()
    }

    /// The selected pixels with the marks drawn in.
    func renderedImage() -> CGImage? {
        guard let selection, let pixels = AreaCapture.pixelRect(for: selection, viewSize: bounds.size,
            imageWidth: image.width, imageHeight: image.height) else { return nil }
        return AreaCapture.render(image, pixels: pixels, elements: elements)
    }

    func selectionInScreen() -> CGRect? {
        guard let selection, let window else { return nil }
        return window.convertToScreen(convert(selection, to: nil))
    }

    /// Where the event happened, kept inside the display.
    private func location(of event: NSEvent) -> CGPoint {
        let raw = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(raw.x, bounds.minX), bounds.maxX), y: min(max(raw.y, bounds.minY), bounds.maxY))
    }

    private func grabbedEdges(at point: CGPoint, of rect: CGRect) -> Edges {
        let t = Self.edgeTolerance
        guard rect.insetBy(dx: -t, dy: -t).contains(point) else { return [] }
        var result: Edges = []
        if abs(point.x - rect.minX) <= t { result.insert(.left) } else if abs(point.x - rect.maxX) <= t { result.insert(.right) }
        if abs(point.y - rect.minY) <= t { result.insert(.bottom) } else if abs(point.y - rect.maxY) <= t { result.insert(.top) }
        return result
    }

    // MARK: Marks

    private var unitScale: CGFloat { max(1, min(bounds.width, bounds.height)) }

    private func unit(_ point: CGPoint) -> MarkupPoint {
        MarkupPoint(x: Double(point.x / max(1, bounds.width)), y: Double(point.y / max(1, bounds.height)))
    }

    private func viewPoint(_ point: MarkupPoint) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * bounds.width, y: CGFloat(point.y) * bounds.height)
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func refreshAnnotations() {
        annotations.elements = elements + (drawing.map { [$0] } ?? [])
        updateControls()
    }

    private func beginMark(at point: CGPoint) {
        let width = (tool == .marker ? Self.markerPoints : Self.strokePoints) / unitScale
        let start = unit(point)
        let points = tool == .pen || tool == .marker ? [start] : [start, start]
        drawing = ImageMarkupElement(tool: tool, points: points, color: color, lineWidth: Double(width),
                                     fontSize: Double(Self.fontPoints / unitScale))
        drag = .mark
        refreshAnnotations()
    }

    private func continueMark(to raw: CGPoint, constrained: Bool) {
        guard var element = drawing, let selection, let first = element.points.first else { return }
        var point = clamp(raw, to: selection)
        switch element.tool {
        case .pen, .marker:
            if let last = element.points.last, hypot(viewPoint(last).x - point.x, viewPoint(last).y - point.y) < 1.5 { return }
            element.points.append(unit(point))
        default:
            let start = viewPoint(first)
            if constrained {
                let dx = point.x - start.x, dy = point.y - start.y
                if element.tool == .rectangle || element.tool == .ellipse {
                    // Shift draws a square or a circle.
                    let side = max(abs(dx), abs(dy))
                    point = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
                } else {
                    // Shift keeps a line or an arrow at a multiple of 45°.
                    let step = CGFloat.pi / 4
                    let angle = (atan2(dy, dx) / step).rounded() * step
                    let length = hypot(dx, dy)
                    point = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
                }
                point = clamp(point, to: selection)
            }
            element.points = [first, unit(point)]
        }
        drawing = element
        refreshAnnotations()
    }

    private func endMark() {
        defer { drawing = nil; drag = .idle; refreshAnnotations() }
        guard let element = drawing, let first = element.points.first, let last = element.points.last else { return }
        if element.tool != .pen && element.tool != .marker {
            let a = viewPoint(first), b = viewPoint(last)
            // A click with a shape tool draws nothing.
            guard hypot(b.x - a.x, b.y - a.y) >= 3 else { return }
        }
        elements.append(element)
    }

    @objc private func undoMark() {
        guard !isEditingText, !elements.isEmpty else { return }
        elements.removeLast()
        refreshAnnotations()
    }

    @objc private func chooseTool(_ sender: NSButton) {
        guard Self.tools.indices.contains(sender.tag) else { return }
        pick(Self.tools[sender.tag].tool)
    }

    private func pick(_ value: ImageMarkupTool) {
        commitText()
        tool = value
        updateControls()
        window?.makeFirstResponder(self)
        updateCursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    @objc private func chooseColor(_ sender: NSButton) {
        guard MarkupColor.palette.indices.contains(sender.tag) else { return }
        color = MarkupColor.palette[sender.tag]
        textField?.textColor = color.nsColor
        updateControls()
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        guard let selection else { return }
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: Self.fontPoints, weight: .medium)
        field.textColor = color.nsColor
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 2
        let height = ceil(field.fittingSize.height)
        let x = min(max(point.x - 3, selection.minX), max(selection.minX, selection.maxX - 40))
        let y = min(max(point.y - height / 2, selection.minY), max(selection.minY, selection.maxY - height))
        field.frame = CGRect(x: x, y: y, width: 40, height: height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField, let selection else { return }
        let width = ceil(field.attributedStringValue.size().width) + 14
        field.setFrameSize(CGSize(width: min(max(40, width), max(40, selection.maxX - field.frame.minX)), height: field.frame.height))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { discardText(); return true }
        return false
    }

    /// Turns the text being typed into a mark; empty text leaves nothing.
    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        // Where the field shows the text: its cell keeps a small inset.
        let lineHeight = (text as NSString).size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: Self.fontPoints)]).height
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY + max(0, (field.frame.height - lineHeight) / 2))
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elements.append(ImageMarkupElement(tool: .text, points: [unit(origin)], color: color,
                lineWidth: Double(Self.strokePoints / unitScale), text: text, fontSize: Double(Self.fontPoints / unitScale)))
        }
        refreshAnnotations()
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        commitText()
        window?.makeFirstResponder(self)
        let point = location(of: event)
        if tool != .select, let selection, selection.contains(point) {
            if tool == .text { beginText(at: point) } else { beginMark(at: point) }
            return
        }
        if tool == .select, event.clickCount == 2, let selection, selection.contains(point) { complete(.copy); return }
        if let selection, !grabbedEdges(at: point, of: selection).isEmpty {
            drag = .resize(edges: grabbedEdges(at: point, of: selection), original: selection)
        } else if let selection, selection.contains(point) {
            drag = .move(offset: CGSize(width: point.x - selection.minX, height: point.y - selection.minY))
            NSCursor.closedHand.set()
        } else {
            drag = .create(anchor: point)
            selection = nil
            onBegin?()
        }
        toolbar.isHidden = true
        toolsBar.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        switch drag {
        case .idle:
            return
        case .mark:
            continueMark(to: point, constrained: event.modifierFlags.contains(.shift))
        case let .create(anchor):
            var width = abs(point.x - anchor.x), height = abs(point.y - anchor.y)
            // Shift keeps it square, as far as the display allows.
            if event.modifierFlags.contains(.shift) {
                let side = max(width, height)
                width = min(side, point.x >= anchor.x ? bounds.maxX - anchor.x : anchor.x - bounds.minX)
                height = min(side, point.y >= anchor.y ? bounds.maxY - anchor.y : anchor.y - bounds.minY)
                width = min(width, height); height = width
            }
            selection = CGRect(x: point.x >= anchor.x ? anchor.x : anchor.x - width,
                               y: point.y >= anchor.y ? anchor.y : anchor.y - height,
                               width: width, height: height)
        case let .move(offset):
            guard let current = selection else { return }
            let x = min(max(point.x - offset.width, bounds.minX), bounds.maxX - current.width)
            let y = min(max(point.y - offset.height, bounds.minY), bounds.maxY - current.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: current.size)
        case let .resize(grabbed, original):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if grabbed.contains(.left) { minX = point.x }
            if grabbed.contains(.right) { maxX = point.x }
            if grabbed.contains(.bottom) { minY = point.y }
            if grabbed.contains(.top) { maxY = point.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .mark = drag { endMark(); return }
        drag = .idle
        // A click without a drag selects nothing.
        if let selection, selection.width < 3 || selection.height < 3 { self.selection = nil }
        updateChrome()
        updateCursor(at: location(of: event))
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: location(of: event)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: location(of: event)) }

    private func updateCursor(at point: CGPoint) {
        guard case .idle = drag else { return }
        for bar in [toolbar, toolsBar] where !bar.isHidden && bar.frame.contains(point) { NSCursor.arrow.set(); return }
        guard let selection else { NSCursor.crosshair.set(); return }
        if tool != .select && selection.contains(point) {
            (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            return
        }
        let grabbed = grabbedEdges(at: point, of: selection)
        if grabbed == [.left] || grabbed == [.right] { NSCursor.resizeLeftRight.set() }
        else if grabbed == [.top] || grabbed == [.bottom] { NSCursor.resizeUpDown.set() }
        else if grabbed.isEmpty && selection.contains(point) { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { handleKey(event) }
    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, flags) {
        case (53, _), (13, .command):          // Esc, ⌘W
            onFinish?(nil)
        case (36, _), (76, _), (8, .command):  // Return, Enter, ⌘C
            if selection != nil { complete(.copy) } else { NSSound.beep() }
        case (1, .command):                    // ⌘S
            if selection != nil { complete(.save) } else { NSSound.beep() }
        case (6, .command):                    // ⌘Z
            undoMark()
        case (0, .command):                    // ⌘A
            onBegin?()
            selection = bounds
        case (123, _), (124, _), (125, _), (126, _):
            nudge(event.keyCode, by: flags.contains(.shift) ? 10 : 1)
        default:
            if flags.isEmpty, let entry = Self.tools.first(where: { $0.key == event.keyCode }) { pick(entry.tool) }
        }
    }

    /// Typed text becomes a mark before the capture is kept.
    private func complete(_ output: AreaCapture.Output) {
        commitText()
        onFinish?(output)
    }

    private func nudge(_ keyCode: UInt16, by step: CGFloat) {
        guard let current = selection, case .idle = drag else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = -step
        default: dy = step
        }
        let x = min(max(current.minX + dx, bounds.minX), bounds.maxX - current.width)
        let y = min(max(current.minY + dy, bounds.minY), bounds.maxY - current.height)
        selection = CGRect(origin: CGPoint(x: x, y: y), size: current.size)
    }

    @objc private func copySelection() { complete(.copy) }
    @objc private func saveSelection() { complete(.save) }
    @objc private func cancelCapture() { onFinish?(nil) }

    // MARK: Drawing

    private func updateChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let dim = CGMutablePath()
        dim.addRect(bounds)
        guard let selection, selection.width > 0, selection.height > 0 else {
            dimLayer.path = dim
            outlineLayer.path = nil; dashLayer.path = nil; handlesLayer.path = nil
            annotations.isHidden = true
            sizeBadge.isHidden = true
            toolbar.isHidden = true
            toolsBar.isHidden = true
            hintBadge.isHidden = !showsHint
            hintBadge.setFrameOrigin(CGPoint(x: (bounds.width - hintBadge.frame.width) / 2,
                                             y: bounds.height * 0.75 - hintBadge.frame.height / 2))
            return
        }
        hintBadge.isHidden = true
        dim.addRect(selection)
        dimLayer.path = dim
        let border = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        outlineLayer.path = border
        dashLayer.path = border
        annotations.isHidden = false
        annotations.frame = selection
        annotations.displayRect = CGRect(x: -selection.minX, y: -selection.minY, width: bounds.width, height: bounds.height)

        let handles = CGMutablePath()
        let handleSide: CGFloat = 6
        for x in [selection.minX, selection.midX, selection.maxX] {
            for y in [selection.minY, selection.midY, selection.maxY] where !(x == selection.midX && y == selection.midY) {
                handles.addRect(CGRect(x: x - handleSide / 2, y: y - handleSide / 2, width: handleSide, height: handleSide))
            }
        }
        handlesLayer.path = handles

        if let pixels = AreaCapture.pixelRect(for: selection, viewSize: bounds.size, imageWidth: image.width, imageHeight: image.height) {
            sizeBadge.text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        }
        sizeBadge.isHidden = false
        let margin = Self.margin
        var badgeOrigin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if badgeOrigin.y + sizeBadge.frame.height > bounds.maxY - 2 { badgeOrigin.y = selection.maxY - sizeBadge.frame.height - 6; badgeOrigin.x += 6 }
        badgeOrigin.x = min(max(badgeOrigin.x, bounds.minX + 2), bounds.maxX - sizeBadge.frame.width - 2)
        sizeBadge.setFrameOrigin(badgeOrigin)

        let adjusting: Bool
        switch drag {
        case .create, .move, .resize: adjusting = true
        case .idle, .mark: adjusting = false
        }
        toolbar.isHidden = adjusting
        toolsBar.isHidden = adjusting
        guard !adjusting else { return }

        // Actions under the selection, right aligned; tools on its right.
        let size = toolbar.frame.size
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - size.height - margin)
        if origin.y < bounds.minY + margin { origin.y = selection.maxY + margin }
        if origin.y + size.height > bounds.maxY - margin { origin.y = selection.minY + margin }
        origin.x = min(max(origin.x, bounds.minX + margin), bounds.maxX - size.width - margin)
        toolbar.setFrameOrigin(origin)

        let barSize = toolsBar.frame.size
        var barOrigin = CGPoint(x: selection.maxX + margin, y: selection.maxY - barSize.height)
        if barOrigin.x + barSize.width > bounds.maxX - margin { barOrigin.x = selection.minX - barSize.width - margin }
        if barOrigin.x < bounds.minX + margin { barOrigin.x = selection.maxX - barSize.width - margin }
        barOrigin.x = min(max(barOrigin.x, bounds.minX + margin), bounds.maxX - barSize.width - margin)
        barOrigin.y = min(max(barOrigin.y, bounds.minY + margin), bounds.maxY - barSize.height - margin)
        toolsBar.setFrameOrigin(barOrigin)
    }
}
