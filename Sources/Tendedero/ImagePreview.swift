import AppKit

private final class ImagePreviewSurface: NSView {
    var arrange: () -> Void = {}
    override func layout() { super.layout(); arrange() }
}

/// Menu-only annotation actions share the exact canvas operations used by the
/// toolbar. They intentionally carry no synthetic keyboard events.
enum ImageMarkupCommand: CaseIterable, Equatable {
    case resetZoom, undo, redo, deleteSelected, clear, save, finishEditing, styles
}

/// Browsing keeps the borderless fit/zoom. Markup adds an editable vector layer
/// against an immutable full-resolution source; the display thumbnail is never exported.
@MainActor final class ImagePreview: NSObject, NSWindowDelegate {
    let window: NSPanel
    let scroll: ZoomScrollView
    let canvas: ImageMarkupCanvas
    let toolbar = ImageMarkupToolbar()
    let controls = PreviewControls(markup: true)
    var onClose: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onSaveMarkup: ((ImageMarkupDocument) -> Bool)?
    private(set) var isMarkupEditing = false
    private(set) var currentURL: URL?
    private var sourceURL: URL
    private var savedDocument = ImageMarkupDocument()
    private let surface: ImagePreviewSurface
    private var hovering = false
    private var preferredImageSize: NSSize
    private var browsingFrame: NSRect?
    private var saveError: String?
    private var saving = false
    private var cropEntryWasMarkupEditing: Bool?
    private var displayedCrop: MarkupCrop?
    private var displayedCropping = false
    var isCropping: Bool { canvas.isCropping }
    var hasUnsavedMarkup: Bool { canvas.document != savedDocument || canvas.isTextEditing }
    var document: ImageMarkupDocument { canvas.document }

    init?(url: URL, keyboardBindings: KeyboardBindings? = nil, window existing: ActionPreviewPanel? = nil) {
        guard let image = makeThumbnail(url, maxPixels: 4000), image.size.width > 0, image.size.height > 0 else { return nil }
        let visible = (existing?.screen ?? LinePanel.screenUnderPointer())?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 750)
        let fit = min(1, min(visible.width * 0.88 / image.size.width, visible.height * 0.82 / image.size.height))
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        window = makePreviewPanel(size: size, reusing: existing)
        scroll = ZoomScrollView(frame: NSRect(origin: .zero, size: size))
        canvas = ImageMarkupCanvas(frame: NSRect(origin: .zero, size: size))
        surface = ImagePreviewSurface(frame: NSRect(origin: .zero, size: size))
        sourceURL = url; currentURL = url; preferredImageSize = image.size
        super.init()
        controls.keyboardBindings = keyboardBindings ?? KeyboardBindings(defaults: .standard)
        (window as? ActionPreviewPanel)?.onKey = { [weak self] in self?.routeKey($0) ?? false }
        (window as? ActionPreviewPanel)?.onKeyUp = { [weak self] event in
            guard event.keyCode == 49, self?.canvas.spaceHeld == true else { return false }
            self?.canvas.spaceHeld = false; return true
        }
        window.title = L("Image preview") + " · 100%"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .floating; window.delegate = self; window.isMovableByWindowBackground = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.fittedSize = size
        canvas.image = image; canvas.imageScaling = .scaleAxesIndependently; canvas.zoomScroll = scroll
        canvas.setAccessibilityLabel(L("Image preview")); scroll.documentView = canvas
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Upload to R2")) { [weak self] in self?.controls.onUpload() })
        menu.addItem(ClosureMenuItem(L("Markup image")) { [weak self] in self?.beginMarkup() })
        menu.addItem(ClosureMenuItem(L("Crop image")) { [weak self] in self?.beginCrop() })
        menu.addItem(ClosureMenuItem(L("Reset zoom")) { [weak scroll] in scroll?.resetZoom() })
        menu.addItem(ClosureMenuItem(L("Close preview")) { [weak self] in self?.requestClose() })
        canvas.menu = menu
        scroll.onZoom = { [weak self] scale in self?.window.title = L("Image preview") + " · \(Int(scale * 100))%" }
        window.contentView = surface
        surface.addSubview(scroll); surface.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controls.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10)])
        toolbar.isHidden = true; controls.isHidden = true
        surface.arrange = { [weak self] in self?.layoutSurface() }
        scroll.onHover = { [weak self] value in self?.hovering = value; self?.updateControlsVisibility() }
        canvas.onChange = { [weak self] in self?.saveError = nil; self?.refreshCanvasGeometry(); self?.refreshToolbar() }
        canvas.onSelection = { [weak self] in self?.refreshCanvasGeometry(); self?.refreshToolbar() }
        controls.onMarkup = { [weak self] in self?.toggleMarkup() }
        controls.onClose = { [weak self] in self?.requestClose() }
        toolbar.onTool = { [weak self] value in self?.canvas.setTool(value); self?.refreshToolbar() }
        toolbar.onColor = { [weak self] in self?.canvas.applyStyle(color: $0) }
        toolbar.onWidth = { [weak self] in self?.canvas.applyStyle(width: $0) }
        toolbar.onFill = { [weak self] in self?.canvas.applyStyle(fill: $0) }
        toolbar.onFontSize = { [weak self] in self?.canvas.applyStyle(fontSize: $0) }
        toolbar.onUndo = { [weak self] in self?.canvas.undoMarkup() }
        toolbar.onRedo = { [weak self] in self?.canvas.redoMarkup() }
        toolbar.onDelete = { [weak self] in self?.canvas.deleteSelected() }
        toolbar.onClear = { [weak self] in self?.canvas.clearMarkup() }
        toolbar.onDone = { [weak self] in _ = self?.finishMarkup() }
        toolbar.onCrop = { [weak self] in
            guard let self else { return }
            if self.isCropping { self.cancelCrop() } else { self.beginCrop() }
        }
        toolbar.onApplyCrop = { [weak self] in _ = self?.applyCrop() }
        toolbar.onCancelCrop = { [weak self] in self?.cancelCrop() }
        toolbar.onResetCrop = { [weak self] in self?.canvas.resetCropSelection() }
        if existing == nil { window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)) }
    }
    func configureMarkup(document: ImageMarkupDocument, sourceURL: URL) {
        guard let image = makeThumbnail(sourceURL, maxPixels: 4000) else { return }
        self.sourceURL = sourceURL; savedDocument = document
        canvas.image = image; preferredImageSize = image.size; canvas.load(document)
        saveError = nil; refreshCanvasGeometry(); refreshToolbar(); layoutSurface()
    }
    // Saving can move the immutable base into managed storage. Keep the active
    // selection, undo stack and viewport rather than reloading the same item.
    func updateMarkupSource(_ url: URL, renderedURL: URL) { sourceURL = url; currentURL = renderedURL }
    @discardableResult func replaceImage(url: URL) -> Bool {
        guard flushEdits() else { return false }
        guard url != currentURL else { return true }
        guard let image = makeThumbnail(url, maxPixels: 4000), image.size.width > 0, image.size.height > 0 else { return false }
        currentURL = url; sourceURL = url; preferredImageSize = image.size
        canvas.image = image; canvas.load(ImageMarkupDocument()); savedDocument = ImageMarkupDocument(); saveError = nil
        cropEntryWasMarkupEditing = nil; displayedCrop = nil; displayedCropping = false
        if isMarkupEditing { layoutSurface(); scroll.resetZoom() } else { fitBrowsingWindow() }
        refreshToolbar(); return true
    }
    func beginMarkup() {
        guard !isMarkupEditing else { return }
        do { _ = try ImageMarkupRenderer.sourceImage(sourceURL) }
        catch { saveError = error.localizedDescription; controls.position.stringValue = error.localizedDescription; return }
        browsingFrame = window.frame; isMarkupEditing = true; canvas.isMarkupEditing = true
        window.isMovableByWindowBackground = false; toolbar.isHidden = false
        controls.installLeadingAccessory(toolbar)
        surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        surface.layer?.cornerRadius = 16; surface.layer?.masksToBounds = true
        let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 750)
        let size = NSSize(width: min(visible.width * 0.94, max(820, window.frame.width)), height: min(visible.height * 0.88, max(480, window.frame.height)))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(NSRect(x: max(visible.minX, min(visible.maxX - size.width, center.x - size.width / 2)),
            y: max(visible.minY, min(visible.maxY - size.height, center.y - size.height / 2)), width: size.width, height: size.height), display: true)
        layoutSurface(); scroll.resetZoom(); window.makeFirstResponder(canvas)
        refreshToolbar(); updateControlsVisibility()
    }
    @discardableResult func finishMarkup() -> Bool {
        guard flushEdits() else { return false }
        isMarkupEditing = false; canvas.isMarkupEditing = false; canvas.spaceHeld = false; cropEntryWasMarkupEditing = nil
        toolbar.closeTransientUI(); toolbar.isHidden = true; controls.installLeadingAccessory(nil)
        window.isMovableByWindowBackground = true
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        fitBrowsingWindow(); browsingFrame = nil; updateControlsVisibility(); return true
    }
    func toggleMarkup() { if isMarkupEditing { _ = finishMarkup() } else { beginMarkup() } }
    func beginCrop() {
        guard !isCropping else { return }
        let wasEditing = isMarkupEditing
        beginMarkup()
        guard isMarkupEditing else { return }
        cropEntryWasMarkupEditing = wasEditing
        canvas.beginCrop(); refreshCanvasGeometry(); refreshToolbar()
        scroll.resetZoom(); window.makeFirstResponder(canvas)
    }
    @discardableResult func applyCrop() -> Bool {
        guard isCropping else { return true }
        let returnToBrowsing = cropEntryWasMarkupEditing == false
        guard canvas.applyCrop() else { return false }
        cropEntryWasMarkupEditing = nil
        guard flushEdits() else { return false }
        if returnToBrowsing { return finishMarkup() }
        refreshCanvasGeometry(); refreshToolbar(); return true
    }
    func cancelCrop() {
        guard isCropping else { return }
        let returnToBrowsing = cropEntryWasMarkupEditing == false
        canvas.cancelCrop(); cropEntryWasMarkupEditing = nil
        if returnToBrowsing { _ = finishMarkup() }
        else { refreshCanvasGeometry(); refreshToolbar() }
    }
    @discardableResult func perform(_ action: KeyboardAction) -> Bool {
        let tools: [KeyboardAction: ImageMarkupTool] = [.markupSelect: .select, .markupPen: .pen, .markupMarker: .marker,
            .markupRectangle: .rectangle, .markupEllipse: .ellipse, .markupArrow: .arrow, .markupLine: .line, .markupText: .text]
        if let tool = tools[action] {
            beginMarkup()
            guard isMarkupEditing else { return false }
            canvas.setTool(tool); refreshToolbar(); window.makeFirstResponder(canvas); return true
        }
        switch action {
        case .cropImage:
            if isCropping { cancelCrop() } else { beginCrop() }
            return true
        case .markup: toggleMarkup(); return true
        case .close, .preview: requestClose(); return true
        default: return false
        }
    }
    @discardableResult func performMarkupCommand(_ command: ImageMarkupCommand) -> Bool {
        if command == .resetZoom { scroll.resetZoom(); return true }
        if !isMarkupEditing, command == .undo || command == .redo {
            if command == .undo { guard canvas.canUndo else { return false }; canvas.undoMarkup() }
            else { guard canvas.canRedo else { return false }; canvas.redoMarkup() }
            return flushEdits()
        }
        if command == .styles { beginMarkup() }
        guard isMarkupEditing else { return false }
        switch command {
        case .undo: guard canvas.canUndo || canvas.isTextEditing else { return false }; canvas.undoMarkup()
        case .redo: guard canvas.canRedo else { return false }; canvas.redoMarkup()
        case .deleteSelected: guard canvas.selectedID != nil else { return false }; canvas.deleteSelected()
        case .clear: guard !canvas.document.elements.isEmpty || canvas.isTextEditing else { return false }; canvas.clearMarkup()
        case .save: return flushEdits()
        case .finishEditing: return finishMarkup()
        case .styles:
            surface.layoutSubtreeIfNeeded()
            toolbar.styleButton.performClick(nil)
        case .resetZoom: break
        }
        refreshToolbar(); return true
    }
    @discardableResult func flushEdits() -> Bool {
        if saving { return true }
        // Leaving, copying or navigating saves the chosen crop just like marks.
        // Escape explicitly cancels it before reaching this save path.
        if isCropping {
            guard canvas.applyCrop() else { return false }
            cropEntryWasMarkupEditing = nil
        }
        canvas.finishTextEditing()
        guard canvas.document != savedDocument else { return true }
        do { _ = try canvas.document.validated() }
        catch { saveError = error.localizedDescription; refreshToolbar(); return false }
        saving = true
        defer { saving = false }
        guard onSaveMarkup?(canvas.document) == true else {
            saveError = L("Image changes could not be saved. Your edits are still here."); refreshToolbar(); return false
        }
        savedDocument = canvas.document; saveError = nil; refreshToolbar(); return true
    }
    func requestClose() { if flushEdits() { window.close() } }
    func show() { window.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flushEdits() }
    func windowWillClose(_ notification: Notification) { toolbar.closeTransientUI(); canvas.cancelGesture(); onClose?() }
    func windowDidResignKey(_ notification: Notification) { canvas.cancelGesture() }
    func routeKey(_ event: NSEvent) -> Bool {
        // Native style popovers and the color panel own their editing/navigation
        // keys. A Space or Delete here must never reach the image canvas.
        if toolbar.ownsKeyboardInput { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let bindings = controls.keyboardBindings
        if bindings.action(for: event, in: .imagePreview) == .commandPalette, !canvas.isTextEditing || !flags.intersection([.command, .control]).isEmpty {
            guard flushEdits() else { return true }
            return onKey?(event) ?? false
        }
        if canvas.isTextEditing {
            if event.keyCode == 53 || (flags.contains(.command) && [36, 76].contains(event.keyCode)) {
                canvas.finishTextEditing(); refreshToolbar(); return true
            }
            return false
        }
        if isCropping {
            if event.keyCode == 53 && flags.isEmpty { cancelCrop(); return true }
            if [36, 76].contains(event.keyCode) && (flags.isEmpty || flags == .command) { _ = applyCrop(); return true }
        }
        if !isMarkupEditing, flags.contains(.command), event.keyCode == 6 {
            return performMarkupCommand(flags.contains(.shift) ? .redo : .undo)
        }
        if isMarkupEditing {
            if event.keyCode == 49 && flags.isEmpty { canvas.spaceHeld = true; return true }
            if flags.contains(.command) && event.keyCode == 6 { flags.contains(.shift) ? canvas.redoMarkup() : canvas.undoMarkup(); return true }
            if flags == [.command] && event.keyCode == 1 { _ = flushEdits(); return true }
            if event.keyCode == 53 || (flags.contains(.command) && [36, 76].contains(event.keyCode)) { _ = finishMarkup(); return true }
            if flags.isEmpty && [51, 117].contains(event.keyCode) { canvas.deleteSelected(); return true }
            if let action = bindings.action(for: event, in: .imageMarkup) {
                if perform(action) { return true }
            }
        }
        let action = bindings.action(for: event, in: .imagePreview)
        if let action, perform(action) { return true }
        if action != nil, !flushEdits() { return true }
        return onKey?(event) ?? false
    }
    private func refreshToolbar() {
        toolbar.setCropMode(isCropping)
        if isMarkupEditing { controls.installLeadingAccessory(toolbar) }
        let status = saveError ?? (isCropping ? L("Drag to select the crop area. Enter applies; Esc cancels.") : hasUnsavedMarkup ? L("Unsaved image changes") : L("Image changes saved"))
        toolbar.update(tool: canvas.tool, color: canvas.color, width: canvas.lineWidth, fill: canvas.filled,
            canUndo: canvas.canUndo, canRedo: canvas.canRedo, hasSelection: canvas.selectedID != nil, status: status,
            selectionTool: canvas.selected?.tool, fontSize: canvas.selected?.fontSize ?? canvas.fontSize, isError: saveError != nil, isDirty: hasUnsavedMarkup)
        toolbar.refreshKeyHints(controls.keyboardBindings)
        controls.markupButton?.contentTintColor = isMarkupEditing ? .controlAccentColor : .labelColor
        controls.markupButton?.toolTip = L("Markup image") + " · " + controls.keyboardBindings.title(.markup)
    }
    private func updateControlsVisibility() { controls.isHidden = !(isMarkupEditing || hovering) || window.frame.width < 280 }
    private var displayedImageSize: NSSize {
        let crop = isCropping ? MarkupCrop.full : canvas.document.crop ?? .full
        return NSSize(width: max(1, preferredImageSize.width * crop.width), height: max(1, preferredImageSize.height * crop.height))
    }
    private func refreshCanvasGeometry() {
        guard displayedCrop != canvas.document.crop || displayedCropping != isCropping else { return }
        displayedCrop = canvas.document.crop; displayedCropping = isCropping
        if isMarkupEditing { layoutSurface(); scroll.resetZoom() }
        else { fitBrowsingWindow() }
    }
    private func layoutSurface() {
        guard surface.bounds.width > 0, surface.bounds.height > 0 else { return }
        if isMarkupEditing {
            toolbar.setCompact(surface.bounds.width - 20 < controls.baseWidth + ImageMarkupToolbar.expandedWidth + 11)
            controls.installLeadingAccessory(toolbar)
            controls.layoutSubtreeIfNeeded()
            let topInset = controls.fittingSize.height + 22
            let area = NSRect(x: 12, y: 12, width: max(1, surface.bounds.width - 24), height: max(1, surface.bounds.height - topInset - 12))
            let imageSize = displayedImageSize
            let fit = min(area.width / imageSize.width, area.height / imageSize.height)
            let size = NSSize(width: imageSize.width * fit, height: imageSize.height * fit)
            scroll.frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            if scroll.fittedSize != size { scroll.fittedSize = size; scroll.resetZoom() }
        } else {
            scroll.frame = surface.bounds
            if scroll.fittedSize != surface.bounds.size { scroll.fittedSize = surface.bounds.size; scroll.resetZoom() }
        }
    }
    private func fitBrowsingWindow() {
        let visible = window.screen?.visibleFrame ?? LinePanel.screenUnderPointer()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 750)
        let imageSize = displayedImageSize
        let fit = min(1, min(visible.width * 0.88 / imageSize.width, visible.height * 0.82 / imageSize.height))
        let size = NSSize(width: imageSize.width * fit, height: imageSize.height * fit)
        let frame = browsingFrame ?? window.frame
        window.setFrame(NSRect(x: max(visible.minX, min(visible.maxX - size.width, frame.midX - size.width / 2)),
            y: max(visible.minY, min(visible.maxY - size.height, frame.midY - size.height / 2)), width: size.width, height: size.height), display: true)
        layoutSurface(); scroll.resetZoom()
    }
}
