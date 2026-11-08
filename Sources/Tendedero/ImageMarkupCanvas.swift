import AppKit
import QuartzCore

/// Pointer input belongs to the document, including through a transparent overlay.
@MainActor private final class ImageMarkupOverlay: NSView {
    var render: ((NSRect) -> Void)?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { render?(dirtyRect) }
}

/// The image and its marks share one document view, so zooming/panning cannot
/// separate the overlay from the pixels. Persisted geometry is always unit based.
@MainActor final class ImageMarkupCanvas: NSImageView, NSTextViewDelegate {
    private let baseImageLayer = CALayer()
    private let overlay = ImageMarkupOverlay()
    private var retainedBaseImage: CGImage?
#if DEBUG || STANDALONE_TESTS
    private(set) var baseImagePreparationCount = 0
    private(set) var baseImageGeometryCount = 0
    private(set) var overlayDrawCount = 0
    var retainedBaseImageForTesting: CGImage? { retainedBaseImage }
    var retainedBaseLayerForTesting: CALayer { baseImageLayer }
#endif
    override var isOpaque: Bool { false }
    override var image: NSImage? {
        didSet { prepareBaseImage(); invalidateOverlay() }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); configureCompositing()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder); configureCompositing()
    }
    private func configureCompositing() {
        wantsLayer = true
        layer?.masksToBounds = true
        baseImageLayer.contentsGravity = .resize
        baseImageLayer.minificationFilter = .trilinear
        baseImageLayer.magnificationFilter = .linear
        baseImageLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "contentsScale": NSNull()]
        layer?.addSublayer(baseImageLayer)
        overlay.wantsLayer = true
        overlay.render = { [weak self] rect in self?.drawOverlay(rect) }
        addSubview(overlay)
        prepareBaseImage(); invalidateOverlay()
    }
    private func prepareBaseImage() {
        // ImagePreview supplies an orientation-correct, decoded thumbnail. Keep
        // those exact pixels on the compositor instead of rasterizing them with
        // every pointer event. A tight crop changes the layer frame, never the
        // image allocation or the persisted original.
        let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: [.interpolation: NSImageInterpolation.high])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        retainedBaseImage = pixels
        baseImageLayer.contents = pixels
        CATransaction.commit()
#if DEBUG || STANDALONE_TESTS
        if pixels != nil { baseImagePreparationCount += 1 }
#endif
    }
    private func synchronizeCompositingGeometry() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if baseImageLayer.frame != imageFrame {
            baseImageLayer.frame = imageFrame
#if DEBUG || STANDALONE_TESTS
            baseImageGeometryCount += 1
#endif
        }
        let scale = window?.backingScaleFactor ?? 1
        if baseImageLayer.contentsScale != scale { baseImageLayer.contentsScale = scale }
        if overlay.frame != bounds { overlay.frame = bounds }
        if overlay.bounds != bounds { overlay.bounds = bounds }
        CATransaction.commit()
    }
    private func invalidateOverlay() {
        synchronizeCompositingGeometry()
        overlay.needsDisplay = true
    }
    override func layout() { super.layout(); synchronizeCompositingGeometry() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); invalidateOverlay() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); invalidateOverlay() }
    weak var zoomScroll: ZoomScrollView?
    var onChange: () -> Void = {}
    var onSelection: () -> Void = {}
    private(set) var document = ImageMarkupDocument()
    private(set) var selectedID: UUID?
    private(set) var textEditor: NSTextView?
    var isMarkupEditing = false { didSet { invalidateOverlay(); window?.invalidateCursorRects(for: self) } }
    var tool: ImageMarkupTool = .pen
    var color: MarkupColor = .red
    var lineWidth: Double = 0.008
    var filled = false
    var fontSize: Double = 0.05
    private var undoDocuments = [ImageMarkupDocument]()
    private var redoDocuments = [ImageMarkupDocument]()
    private var draft: ImageMarkupElement?
    private var dragStart: NSPoint?
    private var dragDocument: ImageMarkupDocument?
    private var resizing = false
    private var panning = false
    private var textID: UUID?
    private var textPoint = MarkupPoint(x: 0.1, y: 0.1)
    private var textViewport: NSScrollView?
    private(set) var isCropping = false
    private(set) var cropSelection: MarkupCrop?
    private struct CropEdges: OptionSet {
        let rawValue: Int
        static let left = Self(rawValue: 1), right = Self(rawValue: 2)
        static let bottom = Self(rawValue: 4), top = Self(rawValue: 8)
    }
    private enum CropDrag {
        case create(NSPoint), move(NSRect), resize(NSRect, CropEdges)
    }
    private var cropDrag: CropDrag?
    private var cropDragSelection: MarkupCrop?
    var spaceHeld = false { didSet { window?.invalidateCursorRects(for: self) } }
    var canUndo: Bool { !undoDocuments.isEmpty }
    var canRedo: Bool { !redoDocuments.isEmpty }
    private var remainingPoints: Int { max(0, ImageMarkupDocument.maximumPoints - document.elements.reduce(0) { $0 + $1.points.count }) }
    var selected: ImageMarkupElement? { document.elements.first { $0.id == selectedID } }
    var isTextEditing: Bool { textEditor != nil }
    /// The complete original image, expressed in the cropped canvas's space.
    /// Marks keep their original normalized coordinates across every crop.
    var imageFrame: NSRect {
        guard !isCropping, let crop = document.crop else { return bounds }
        let width = bounds.width / CGFloat(crop.width), height = bounds.height / CGFloat(crop.height)
        return NSRect(x: bounds.minX - CGFloat(crop.x) * width, y: bounds.minY - CGFloat(crop.y) * height,
                      width: width, height: height)
    }
    func cancelGesture() {
        // A transform mutates the live document while the mouse moves; only
        // mouseUp commits it to undo. Losing focus discards that unfinished
        // transform, just as it discards an unfinished pen/shape draft.
        if tool == .select, let original = dragDocument { document = original }
        if cropDrag != nil { cropSelection = cropDragSelection; cropDrag = nil; cropDragSelection = nil; onSelection() }
        zoomScroll?.endPan(); panning = false; spaceHeld = false
        draft = nil; dragStart = nil; dragDocument = nil; resizing = false; invalidateOverlay()
    }
    override var acceptsFirstResponder: Bool { true }
    // The floating nonactivating preview can remain non-key while another app
    // is active. NSImageView otherwise discards the click before mouseDown.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isMarkupEditing || isCropping || super.acceptsFirstMouse(for: event)
    }
    override var mouseDownCanMoveWindow: Bool { !isCropping && !isMarkupEditing && zoomScroll?.canPan != true }

    func load(_ value: ImageMarkupDocument) {
        cancelGesture()
        textViewport?.removeFromSuperview(); textViewport = nil
        textEditor?.removeFromSuperview(); textEditor = nil; textID = nil
        document = value; selectedID = nil; draft = nil
        isCropping = false; cropSelection = nil
        undoDocuments.removeAll(); redoDocuments.removeAll(); invalidateOverlay()
    }
    // The backing layer's own contents stay transparent. Its retained image
    // sublayer sits below the separate vector overlay and native text editor.
    override func draw(_ dirtyRect: NSRect) {}
    private func drawOverlay(_ dirtyRect: NSRect) {
#if DEBUG || STANDALONE_TESTS
        overlayDrawCount += 1
#endif
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        ImageMarkupRenderer.draw(elements: document.elements, in: imageFrame)
        if let draft { ImageMarkupRenderer.draw(elements: [draft], in: imageFrame) }
        if isCropping { drawCropOverlay() }
        else if isMarkupEditing, tool == .select, textEditor == nil, let selected {
            let box = selected.bounds(in: imageFrame).insetBy(dx: -4, dy: -4)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: box); path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
            for point in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                          NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
                NSColor.white.setFill(); NSColor.controlAccentColor.setStroke()
                let handle = NSBezierPath(roundedRect: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                handle.fill(); handle.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: spaceHeld || (!isMarkupEditing && !isCropping) ? (zoomScroll?.canPan == true ? .openHand : .arrow) : isCropping ? .crosshair : tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }
    private func unit(_ point: NSPoint) -> MarkupPoint {
        let frame = imageFrame
        return MarkupPoint(x: max(0, min(1, (point.x - frame.minX) / max(1, frame.width))),
                           y: max(0, min(1, (point.y - frame.minY) / max(1, frame.height))))
    }
    private func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
    private func boundedCropPoint(_ value: NSPoint) -> NSPoint {
        NSPoint(x: max(bounds.minX, min(bounds.maxX, value.x)), y: max(bounds.minY, min(bounds.maxY, value.y)))
    }
    private var minimumCropSize: NSSize {
        NSSize(width: min(bounds.width, max(bounds.width * 0.005, min(16, bounds.width * 0.1))),
               height: min(bounds.height, max(bounds.height * 0.005, min(16, bounds.height * 0.1))))
    }
    private func beginCropDrag(at value: NSPoint) {
        let start = boundedCropPoint(value), box = (cropSelection ?? .full).rect(in: bounds)
        dragStart = start; cropDragSelection = cropSelection
        var edges = CropEdges()
        let tolerance: CGFloat = 9
        if box.insetBy(dx: -tolerance, dy: -tolerance).contains(start) {
            if abs(start.x - box.minX) <= tolerance { edges.insert(.left) }
            else if abs(start.x - box.maxX) <= tolerance { edges.insert(.right) }
            if abs(start.y - box.minY) <= tolerance { edges.insert(.bottom) }
            else if abs(start.y - box.maxY) <= tolerance { edges.insert(.top) }
        }
        if !edges.isEmpty { cropDrag = .resize(box, edges) }
        else if cropSelection?.isFullImage != true, box.contains(start) { cropDrag = .move(box) }
        else { cropDrag = .create(start) }
        invalidateOverlay(); onSelection()
    }
    private func updateCropDrag(at value: NSPoint) {
        guard let cropDrag, let start = dragStart, bounds.width > 0, bounds.height > 0 else { return }
        let point = boundedCropPoint(value), minimum = minimumCropSize
        let box: NSRect
        switch cropDrag {
        case let .create(anchor):
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= 2 else { return }
            let width = max(minimum.width, abs(point.x - anchor.x)), height = max(minimum.height, abs(point.y - anchor.y))
            box = NSRect(x: max(bounds.minX, min(bounds.maxX - width, point.x < anchor.x ? anchor.x - width : anchor.x)),
                         y: max(bounds.minY, min(bounds.maxY - height, point.y < anchor.y ? anchor.y - height : anchor.y)),
                         width: width, height: height)
        case let .move(original):
            box = NSRect(x: max(bounds.minX, min(bounds.maxX - original.width, original.minX + point.x - start.x)),
                         y: max(bounds.minY, min(bounds.maxY - original.height, original.minY + point.y - start.y)),
                         width: original.width, height: original.height)
        case let .resize(original, edges):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.contains(.left) { minX = min(maxX - minimum.width, point.x) }
            if edges.contains(.right) { maxX = max(minX + minimum.width, point.x) }
            if edges.contains(.bottom) { minY = min(maxY - minimum.height, point.y) }
            if edges.contains(.top) { maxY = max(minY + minimum.height, point.y) }
            box = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let x = Double((box.minX - bounds.minX) / bounds.width), y = Double((box.minY - bounds.minY) / bounds.height)
        cropSelection = MarkupCrop(x: x, y: y, width: min(1 - x, Double(box.width / bounds.width)),
                                   height: min(1 - y, Double(box.height / bounds.height)))
        invalidateOverlay(); onSelection()
    }
    private func drawCropOverlay() {
        let box = (cropSelection ?? .full).rect(in: bounds)
        NSColor.black.withAlphaComponent(0.55).setFill()
        for rect in [NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: box.minY - bounds.minY),
                     NSRect(x: bounds.minX, y: box.maxY, width: bounds.width, height: bounds.maxY - box.maxY),
                     NSRect(x: bounds.minX, y: box.minY, width: box.minX - bounds.minX, height: box.height),
                     NSRect(x: box.maxX, y: box.minY, width: bounds.maxX - box.maxX, height: box.height)] {
            if rect.width > 0 && rect.height > 0 { NSBezierPath(rect: rect).fill() }
        }
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.75
        for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
            grid.move(to: NSPoint(x: box.minX + box.width * fraction, y: box.minY))
            grid.line(to: NSPoint(x: box.minX + box.width * fraction, y: box.maxY))
            grid.move(to: NSPoint(x: box.minX, y: box.minY + box.height * fraction))
            grid.line(to: NSPoint(x: box.maxX, y: box.minY + box.height * fraction))
        }
        grid.stroke(); NSColor.white.setStroke()
        let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1.5; border.stroke()
        NSColor.white.setFill()
        for point in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.midX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                      NSPoint(x: box.minX, y: box.midY), NSPoint(x: box.maxX, y: box.midY),
                      NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.midX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
            let handle = NSBezierPath(roundedRect: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 1, yRadius: 1)
            handle.fill()
        }
    }
    private func changed(_ previous: ImageMarkupDocument) {
        guard previous != document else { invalidateOverlay(); return }
        undoDocuments.append(previous)
        if undoDocuments.count > 60 { undoDocuments.removeFirst() }
        redoDocuments.removeAll(); invalidateOverlay(); onChange(); onSelection()
    }
    func setTool(_ value: ImageMarkupTool) {
        cancelCrop()
        finishTextEditing(); tool = value; selectedID = nil
        if value == .marker && lineWidth < 0.02 { lineWidth = 0.04; color = .yellow }
        else if value != .marker && lineWidth >= 0.03 { lineWidth = 0.008 }
        invalidateOverlay(); onSelection(); window?.invalidateCursorRects(for: self)
    }
    func applyStyle(color: MarkupColor? = nil, width: Double? = nil, fill: Bool? = nil, fontSize: Double? = nil) {
        finishTextEditing()
        if let color { self.color = color }; if let width { lineWidth = width }; if let fill { filled = fill }
        if let fontSize { self.fontSize = fontSize }
        guard let index = document.elements.firstIndex(where: { $0.id == selectedID }) else { onSelection(); return }
        let previous = document
        if let color { document.elements[index].color = color }
        if let width { document.elements[index].lineWidth = width }
        if let fill { document.elements[index].fill = fill }
        if let fontSize { document.elements[index].fontSize = fontSize }
        changed(previous)
    }
    func beginCrop() {
        finishTextEditing(); cancelGesture(); selectedID = nil
        cropSelection = document.crop ?? .full; isCropping = true
        invalidateOverlay(); onSelection(); window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(self)
    }
    @discardableResult func applyCrop() -> Bool {
        guard isCropping, let selection = cropSelection, selection.isValid else { return false }
        // Complete a live pointer gesture before committing. A following blur
        // must not restore its starting selection or accidentally unapply it.
        cropDrag = nil; cropDragSelection = nil; dragStart = nil
        let previous = document
        document.crop = selection.isFullImage ? nil : selection
        isCropping = false; cropSelection = nil; selectedID = nil
        changed(previous); invalidateOverlay(); onSelection(); window?.invalidateCursorRects(for: self)
        return true
    }
    func cancelCrop() {
        guard isCropping else { return }
        cancelGesture(); isCropping = false; cropSelection = nil
        invalidateOverlay(); onSelection(); window?.invalidateCursorRects(for: self)
    }
    func resetCropSelection() {
        guard isCropping else { return }
        cancelGesture(); cropSelection = .full; invalidateOverlay(); onSelection()
    }
    func undoMarkup() {
        finishTextEditing(); cancelCrop(); guard let previous = undoDocuments.popLast() else { return }
        redoDocuments.append(document); document = previous; selectedID = nil; invalidateOverlay(); onChange(); onSelection()
    }
    func redoMarkup() {
        finishTextEditing(); cancelCrop(); guard let next = redoDocuments.popLast() else { return }
        undoDocuments.append(document); document = next; selectedID = nil; invalidateOverlay(); onChange(); onSelection()
    }
    func deleteSelected() {
        finishTextEditing(); guard let selectedID else { return }
        let previous = document; document.elements.removeAll { $0.id == selectedID }; self.selectedID = nil; changed(previous)
    }
    func clearMarkup() {
        finishTextEditing(); let previous = document; document.elements.removeAll(); selectedID = nil; changed(previous)
    }

    override func mouseDown(with event: NSEvent) {
        if (!isMarkupEditing && !isCropping) || spaceHeld {
            if !isMarkupEditing && !isCropping && event.clickCount == 2 { zoomScroll?.resetZoom() }
            else if let scroll = zoomScroll, scroll.beginPan(at: scroll.viewportPoint(for: event)) { panning = true }
            else if !isMarkupEditing { super.mouseDown(with: event) }
            return
        }
        if isCropping {
            window?.makeFirstResponder(self); beginCropDrag(at: point(event)); return
        }
        finishTextEditing(); window?.makeFirstResponder(self)
        let start = point(event); dragStart = start; dragDocument = document
        if tool == .select {
            if let selected, selected.bounds(in: imageFrame).insetBy(dx: -12, dy: -12).contains(start) {
                let box = selected.bounds(in: imageFrame)
                resizing = [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY), NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)]
                    .contains { hypot($0.x - start.x, $0.y - start.y) < 15 }
            } else { selectedID = hitTestMark(start)?.id; resizing = false }
            if let selected { color = selected.color; lineWidth = selected.lineWidth; filled = selected.fill; fontSize = selected.fontSize }
            if event.clickCount == 2, selected?.tool == .text { beginText(at: selected!.points[0], element: selected) }
            invalidateOverlay(); onSelection(); return
        }
        selectedID = nil; onSelection()
        guard document.elements.count < ImageMarkupDocument.maximumElements,
              remainingPoints >= (tool == .text || tool == .pen || tool == .marker ? 1 : 2) else { return }
        if tool == .text { beginText(at: unit(start)); return }
        let p = unit(start)
        draft = ImageMarkupElement(tool: tool, points: tool == .pen || tool == .marker ? [p] : [p, p], color: color,
                                   lineWidth: lineWidth, fill: filled && (tool == .rectangle || tool == .ellipse), fontSize: fontSize)
        invalidateOverlay()
    }
    override func mouseDragged(with event: NSEvent) {
        if panning, let scroll = zoomScroll { scroll.pan(to: scroll.viewportPoint(for: event)); return }
        if isCropping { updateCropDrag(at: point(event)); return }
        guard isMarkupEditing, let start = dragStart else { super.mouseDragged(with: event); return }
        let p = point(event)
        if tool == .select, let original = dragDocument, let id = selectedID,
           let old = original.elements.first(where: { $0.id == id }), let index = document.elements.firstIndex(where: { $0.id == id }) {
            let dx = Double((p.x - start.x) / max(1, imageFrame.width)), dy = Double((p.y - start.y) / max(1, imageFrame.height))
            var element = old
            if resizing {
                let box = old.bounds(in: imageFrame)
                let anchor = NSPoint(x: start.x < box.midX ? box.maxX : box.minX, y: start.y < box.midY ? box.maxY : box.minY)
                let sx = max(0.05, (p.x - anchor.x) / (abs(start.x - anchor.x) < 1 ? 1 : start.x - anchor.x))
                let sy = max(0.05, (p.y - anchor.y) / (abs(start.y - anchor.y) < 1 ? 1 : start.y - anchor.y))
                element.points = old.points.map { value in
                    let v = value.position(in: imageFrame)
                    return unit(NSPoint(x: anchor.x + (v.x - anchor.x) * sx, y: anchor.y + (v.y - anchor.y) * sy))
                }
                if old.tool == .text { element.fontSize = max(0.005, min(0.5, old.fontSize * Double(max(sx, sy)))) }
            } else {
                let xs = old.points.map(\.x), ys = old.points.map(\.y)
                let x = max(-(xs.min() ?? 0), min(1 - (xs.max() ?? 1), dx))
                let y = max(-(ys.min() ?? 0), min(1 - (ys.max() ?? 1), dy))
                element.points = old.points.map { MarkupPoint(x: $0.x + x, y: $0.y + y) }
            }
            document.elements[index] = element; invalidateOverlay(); return
        }
        guard var value = draft else { return }
        if tool == .pen || tool == .marker {
            let next = unit(p)
            if let previous = value.points.last?.position(in: imageFrame), hypot(p.x - previous.x, p.y - previous.y) < 1 { return }
            if value.points.count < min(ImageMarkupDocument.maximumPointsPerElement, remainingPoints) { value.points.append(next) }
        } else {
            var end = p
            if event.modifierFlags.contains(.shift) {
                let dx = p.x - start.x, dy = p.y - start.y
                if tool == .ellipse || tool == .rectangle {
                    let side = min(abs(dx), abs(dy)); end = NSPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
                } else {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), length = hypot(dx, dy)
                    end = NSPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
                }
            }
            value.points[1] = unit(end)
        }
        draft = value; invalidateOverlay()
    }
    override func mouseUp(with event: NSEvent) {
        if panning { zoomScroll?.endPan(); panning = false; return }
        if isCropping {
            updateCropDrag(at: point(event)); cropDrag = nil; cropDragSelection = nil; dragStart = nil
            invalidateOverlay(); onSelection(); return
        }
        defer { draft = nil; dragStart = nil; dragDocument = nil; resizing = false; invalidateOverlay() }
        guard isMarkupEditing else { super.mouseUp(with: event); return }
        let previous = dragDocument ?? document
        if let draft, document.elements.count < ImageMarkupDocument.maximumElements {
            if draft.tool == .pen || draft.tool == .marker || (draft.points.count == 2 && draft.points[0] != draft.points[1]) {
                document.elements.append(draft); selectedID = draft.id
            }
        }
        changed(previous)
    }
    private func hitTestMark(_ point: NSPoint) -> ImageMarkupElement? {
        document.elements.reversed().first { element in
            let box = element.bounds(in: imageFrame).insetBy(dx: -7, dy: -7)
            guard box.contains(point) else { return false }
            if element.tool == .text || (element.fill && (element.tool == .rectangle || element.tool == .ellipse)) { return true }
            if element.tool == .ellipse {
                let ellipse = element.bounds(in: imageFrame)
                let x = (point.x - ellipse.midX) / max(1, ellipse.width / 2), y = (point.y - ellipse.midY) / max(1, ellipse.height / 2)
                return abs(hypot(x, y) - 1) < 0.18
            }
            if element.tool == .rectangle { return !element.bounds(in: imageFrame).insetBy(dx: 8, dy: 8).contains(point) }
            let values = element.points.map { $0.position(in: imageFrame) }
            let tolerance = max(8, element.lineWidth * min(imageFrame.width, imageFrame.height) / 2 + 5)
            if values.count == 1 { return hypot(point.x - values[0].x, point.y - values[0].y) <= tolerance }
            return zip(values, values.dropFirst()).contains { a, b in
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
                return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= tolerance
            }
        }
    }
    private func beginText(at point: MarkupPoint, element: ImageMarkupElement? = nil) {
        textPoint = point; textID = element?.id
        let viewport = NSScrollView(frame: NSRect(origin: point.position(in: imageFrame), size: NSSize(width: 220, height: 40)))
        viewport.hasHorizontalScroller = true; viewport.hasVerticalScroller = true
        viewport.autohidesScrollers = true; viewport.borderType = .lineBorder
        viewport.drawsBackground = true; viewport.backgroundColor = .textBackgroundColor
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        editor.string = element?.text ?? ""; editor.font = .systemFont(ofSize: max(1, fontSize * min(imageFrame.width, imageFrame.height)), weight: .medium)
        editor.textColor = color.nsColor; editor.backgroundColor = .textBackgroundColor
        editor.isRichText = false; editor.allowsUndo = true
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Persisted text has explicit line breaks only. Soft-wrapping here
        // would show lines that disappear when NSString renders the saved mark.
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 4, height: 4); editor.delegate = self
        editor.setAccessibilityLabel(L("Annotation text")); viewport.wantsLayer = true; viewport.layer?.cornerRadius = 4
        viewport.documentView = editor
        addSubview(viewport); textViewport = viewport; textEditor = editor; selectedID = element?.id
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        window?.makeFirstResponder(editor); if element != nil { editor.selectAll(nil) }
    }
    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, let viewport = textViewport else { return }
        let size = (editor.string as NSString).size(withAttributes: [.font: editor.font ?? NSFont.systemFont(ofSize: 16)])
        let origin = textPoint.position(in: imageFrame)
        viewport.frame = NSRect(x: origin.x, y: origin.y, width: max(120, min(bounds.maxX - origin.x, size.width + 12)), height: max(32, min(bounds.maxY - origin.y, size.height + 12)))
        editor.setFrameSize(NSSize(width: max(viewport.contentSize.width, size.width + 12), height: max(viewport.contentSize.height, size.height + 12)))
        editor.scrollRangeToVisible(editor.selectedRange())
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { finishTextEditing() }
        super.setFrameSize(newSize); invalidateOverlay()
    }
    @discardableResult func finishTextEditing() -> Bool {
        guard let editor = textEditor else { return true }
        let previous = document
        let text = String(String.UnicodeScalarView(editor.string.unicodeScalars.prefix(ImageMarkupDocument.maximumTextLength)))
        textViewport?.removeFromSuperview(); textViewport = nil
        editor.removeFromSuperview(); textEditor = nil; window?.makeFirstResponder(self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var value = ImageMarkupElement(tool: .text, points: [textPoint], color: color, lineWidth: lineWidth, text: text, fontSize: fontSize)
            if let id = textID, let index = document.elements.firstIndex(where: { $0.id == id }) { value.id = id; document.elements[index] = value; selectedID = id }
            else if document.elements.count < ImageMarkupDocument.maximumElements { document.elements.append(value); selectedID = value.id }
        } else if let id = textID { document.elements.removeAll { $0.id == id }; selectedID = nil }
        textID = nil; changed(previous); return true
    }
}
