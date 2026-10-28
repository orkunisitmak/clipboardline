import AppKit
import SwiftUI

/// User-facing text for a Wallet Guard verdict. Notices are short and leave on
/// their own; replacement and lookalike alerts stay until dismissed and keep
/// both addresses visible for a character-by-character comparison.
struct WalletGuardMessage: Equatable {
    struct Row: Equatable { let label: String; let value: String }
    let title: String
    let body: String
    let rows: [Row]
    let persistent: Bool

    init(title: String, body: String, rows: [Row] = [], persistent: Bool) {
        self.title = title; self.body = body; self.rows = rows; self.persistent = persistent
    }

    init?(_ verdict: WalletGuardVerdict) {
        if let alert = verdict.alert {
            switch alert {
            case let .hijack(original, replacement):
                self.init(title: L("Copied address was replaced"),
                          body: L("Your copied address was replaced by another address. This is how clipboard malware steals crypto."),
                          rows: [Row(label: L("You copied"), value: original), Row(label: L("Clipboard now"), value: replacement)], persistent: true)
            case let .poisoning(address, similar):
                self.init(title: L("Possible lookalike address"),
                          body: L("This address starts and ends like one you copied before, but the middle is different. It may be a poisoned lookalike. Compare every character before sending."),
                          rows: [Row(label: L("Copied now"), value: address), Row(label: L("Copied before"), value: similar)], persistent: true)
            }
            return
        }
        switch verdict.notice {
        case .recoveryPhrase?: self.init(title: L("Wallet Guard"), body: L("Recovery phrase not saved. Never paste it into websites or chats."), persistent: false)
        case .privateKey?: self.init(title: L("Wallet Guard"), body: L("Private key not saved. Never paste it into websites or chats."), persistent: false)
        case nil: return nil
        }
    }

    /// One line for the shelf notice and accessibility announcements.
    var summary: String {
        ([title, body] + rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }
}

/// A small floating panel at the top of the active screen. It never activates
/// the application or takes keyboard focus from the app the user copied from.
@MainActor
final class WalletGuardPanel {
    static let noticeDuration: TimeInterval = 6
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private(set) var current: WalletGuardMessage?

    func show(_ message: WalletGuardMessage) {
        current = message
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: WalletGuardView(message: message) { [weak self] in self?.hide() })
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: message.summary, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        dismissal?.cancel(); dismissal = nil
        guard !message.persistent else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration, execute: work)
    }

    func hide() {
        dismissal?.cancel(); dismissal = nil
        current = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(L("Wallet Guard"))
        return panel
    }
}

private struct WalletGuardView: View {
    let message: WalletGuardMessage
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: message.persistent ? "exclamationmark.shield.fill" : "lock.shield.fill")
                    .foregroundStyle(message.persistent ? Color.red : Color.accentColor)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(message.title).font(.headline)
                Spacer(minLength: 12)
                Button(L("Dismiss"), action: dismiss)
            }
            Text(message.body).fixedSize(horizontal: false, vertical: true)
            ForEach(message.rows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                    Text(row.value).font(.system(.body, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(message.persistent ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25)))
    }
}
