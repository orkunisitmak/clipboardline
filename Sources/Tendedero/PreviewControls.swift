import AppKit

/// A content-kind transition keeps the native window, its screen and center.
@MainActor
func makePreviewPanel(size: NSSize, reusing existing: ActionPreviewPanel?) -> ActionPreviewPanel {
    guard let existing else {
        return ActionPreviewPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    existing.makeFirstResponder(nil)
    let visible = existing.screen?.visibleFrame ?? existing.frame
    let center = NSPoint(x: existing.frame.midX, y: existing.frame.midY)
    existing.setFrame(NSRect(x: max(visible.minX, min(visible.maxX - size.width, center.x - size.width / 2)),
        y: max(visible.minY, min(visible.maxY - size.height, center.y - size.height / 2)),
        width: size.width, height: size.height), display: false)
    return existing
}

final class ActionPreviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?
    var onBeforeMouseKeyFocus: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private func nativeControlOwns(_ event: NSEvent) -> Bool {
        guard firstResponder is NSControl, !(firstResponder is NSTextField),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return [36, 76, 49, 48, 123, 124, 125, 126].contains(Int(event.keyCode))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if nativeControlOwns(event) { return super.performKeyEquivalent(with: event) }
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        Self.prepareForMouseKeyFocus(event, isKeyWindow: isKeyWindow, onEntry: onBeforeMouseKeyFocus)
        if nativeControlOwns(event) {
            if event.type == .keyDown, [36, 76].contains(Int(event.keyCode)), let button = firstResponder as? NSButton { button.performClick(nil); return }
            super.sendEvent(event); return
        }
        if event.type == .keyDown, onKey?(event) == true { return }
        if event.type == .keyUp, onKeyUp?(event) == true { return }
        super.sendEvent(event)
    }

    /// A click can make a nonactivating preview key without an app-activation
    /// notification. Capture before AppKit changes focus or calls view actions.
    /// Programmatic own-window handoffs never pass through this mouse path.
    static func prepareForMouseKeyFocus(_ event: NSEvent, isKeyWindow: Bool, onEntry: (() -> Void)?) {
        guard event.type == .leftMouseDown, !isKeyWindow else { return }
        onEntry?()
    }
}

@MainActor
final class PreviewControls: NSVisualEffectView {
    let position = NSTextField(labelWithString: "")
    let uploadButton: NSButton
    let pinButton: NSButton
    let editButton: NSButton?
    let markupButton: NSButton?
    let actionsButton: NSButton
    var onMove: (Int) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onUpload: () -> Void = {}
    var onPin: () -> Void = {}
    var onEdit: () -> Void = {}
    var onClose: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onCommands: () -> Void = {}
    var keyboardBindings = KeyboardBindings(defaults: .standard) { didSet { refreshCommandsHint() } }
    private var isUploaded = false
    private let stack = NSStackView()
    private let accessorySeparator = NSBox()
    private var accessoryWidth: NSLayoutConstraint?
    private var accessoryHeight: NSLayoutConstraint?
    private(set) var leadingAccessory: NSView?
    private var fixedControlsWidth: CGFloat = 0
    var baseWidth: CGFloat { fixedControlsWidth + max(46, position.intrinsicContentSize.width) }
    var contentWidth: CGFloat { baseWidth + (leadingAccessory?.intrinsicContentSize.width ?? 0) + (leadingAccessory == nil ? 0 : 11) }

    /// Markup shares this material and one horizontal row with navigation.
    func installLeadingAccessory(_ accessory: NSView?) {
        if leadingAccessory !== accessory {
            accessoryWidth?.isActive = false; accessoryWidth = nil
            accessoryHeight?.isActive = false; accessoryHeight = nil
            if let previous = leadingAccessory { stack.removeArrangedSubview(previous); previous.removeFromSuperview() }
            if stack.arrangedSubviews.contains(accessorySeparator) { stack.removeArrangedSubview(accessorySeparator) }
            accessorySeparator.removeFromSuperview()
            leadingAccessory = accessory
            if let accessory {
                accessory.translatesAutoresizingMaskIntoConstraints = false
                stack.insertArrangedSubview(accessory, at: 0)
                stack.insertArrangedSubview(accessorySeparator, at: 1)
                accessoryHeight = accessory.heightAnchor.constraint(equalToConstant: 28)
                accessoryHeight?.isActive = true
            }
        }
        if let accessory {
            let width = accessory.intrinsicContentSize.width
            if let accessoryWidth {
                guard accessoryWidth.constant != width else { return }
                accessoryWidth.constant = width
            } else {
                accessoryWidth = accessory.widthAnchor.constraint(equalToConstant: width)
                accessoryWidth?.isActive = true
            }
        }
        invalidateIntrinsicContentSize(); needsLayout = true
    }

    init(editable: Bool = false, markup: Bool = false) {
        uploadButton = Self.button("icloud.and.arrow.up", L("Upload to R2"))
        pinButton = Self.button("pin", L("Pin favorite"))
        markupButton = markup ? Self.button("pencil.tip.crop.circle", L("Markup image")) : nil
        actionsButton = Self.button("command", L("Actions"))
        if editable {
            let button = NSButton(title: L("Edit text"), image: NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)!, target: nil, action: nil)
            button.bezelStyle = .inline; button.isBordered = false; button.imagePosition = .imageLeading
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            editButton = button
        } else { editButton = nil }
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 12
        let previous = Self.button("chevron.left", L("Previous item")), next = Self.button("chevron.right", L("Next item"))
        let copy = Self.button("doc.on.doc", L("Copy")), close = Self.button("xmark", L("Close preview"))
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        position.alignment = .center
        position.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [previous, position, next, copy, uploadButton, pinButton]
        if let editButton { views.append(editButton) }
        if let markupButton { views.append(markupButton) }
        views.append(actionsButton)
        views.append(close)
        for view in views { stack.addArrangedSubview(view) }
        stack.spacing = 5; stack.orientation = .horizontal; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        accessorySeparator.boxType = .separator
        accessorySeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        accessorySeparator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            position.widthAnchor.constraint(greaterThanOrEqualToConstant: 46)])
        fixedControlsWidth = CGFloat(views.count - 1) * 5 + 16 + views.filter { $0 !== position }.reduce(0) { $0 + max(26, $1.fittingSize.width) }
        for (button, action) in [(previous, #selector(previousItem)), (next, #selector(nextItem)),
            (copy, #selector(copyItem)), (uploadButton, #selector(uploadItem)), (pinButton, #selector(pinItem)), (close, #selector(closePreview))] {
            button.target = self; button.action = action
        }
        editButton?.target = self; editButton?.action = #selector(editText)
        markupButton?.target = self; markupButton?.action = #selector(markupImage)
        actionsButton.target = self; actionsButton.action = #selector(showCommands)
        copy.toolTip = L("Copy")
        pinButton.toolTip = L("Pin favorite")
        refreshCommandsHint()
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.bezelStyle = .inline; button.isBordered = false
        button.setAccessibilityLabel(label); button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    func update(position: String, pinned: Bool, uploaded: Bool = false) {
        isUploaded = uploaded
        refreshCommandsHint()
        self.position.stringValue = position
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? L("Unpin") : L("Pin favorite"))
        pinButton.contentTintColor = pinned ? .controlAccentColor : .labelColor
        pinButton.setAccessibilityLabel(pinned ? L("Unpin") : L("Pin favorite"))
        pinButton.toolTip = (pinned ? L("Unpin") : L("Pin favorite")) + " · " + keyboardBindings.title(.pin)
    }
    private func refreshCommandsHint() {
        let hint = keyboardBindings.title(.commandPalette)
        actionsButton.toolTip = L("Actions") + (hint.isEmpty ? "" : " · " + hint)
        let uploadLabel = isUploaded ? L("Copy public link") : L("Upload to R2")
        let uploadHint = keyboardBindings.title(.upload)
        uploadButton.image = NSImage(systemSymbolName: isUploaded ? "link.icloud" : "icloud.and.arrow.up", accessibilityDescription: uploadLabel)
        uploadButton.contentTintColor = isUploaded ? .controlAccentColor : .labelColor
        uploadButton.setAccessibilityLabel(uploadLabel)
        uploadButton.toolTip = uploadLabel + (uploadHint.isEmpty ? "" : " · " + uploadHint)
    }
    func setEditing(_ editing: Bool) {
        editButton?.title = editing ? L("Done") : L("Edit text")
        let label = editing ? L("Finish editing") : L("Edit text")
        editButton?.setAccessibilityLabel(label)
        editButton?.toolTip = label + " · " + keyboardBindings.title(editing ? .finishEditing : .editText)
        editButton?.image = NSImage(systemSymbolName: editing ? "checkmark" : "pencil", accessibilityDescription: nil)
    }
    @objc private func previousItem() { onMove(-1) }
    @objc private func nextItem() { onMove(1) }
    @objc private func copyItem() { onCopy() }
    @objc private func uploadItem() { onUpload() }
    @objc private func pinItem() { onPin() }
    @objc private func editText() { onEdit() }
    @objc private func closePreview() { onClose() }
    @objc private func markupImage() { onMarkup() }
    @objc private func showCommands() { onCommands() }
}
