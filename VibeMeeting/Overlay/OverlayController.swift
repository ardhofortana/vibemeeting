import AppKit
import SwiftUI

/// Floating, always-on-top panel that never steals focus from the meeting app.
final class OverlayPanel: NSPanel {
    /// Zoom (e.g. a title bar double-click when macOS is set to Zoom) switches
    /// the layout instead of filling the screen; the green light toggles it directly.
    var onZoom: (() -> Void)?

    // Lets the Steer field and transcript edits take typing without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func zoom(_ sender: Any?) {
        if let onZoom {
            onZoom()
        } else {
            super.zoom(sender)
        }
    }
}

@MainActor
final class OverlayController {
    private var panel: OverlayPanel?

    static let autosaveName = "VibeMeetingOverlay"
    /// Split layout: transcript and responses side by side.
    static let splitSize = CGSize(width: 860, height: 680)
    static let splitMinSize = CGSize(width: 640, height: 460)
    /// Compact layout: one narrow column.
    static let compactSize = CGSize(width: 420, height: 640)
    static let compactMinSize = CGSize(width: 360, height: 400)

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: MeetingSession, app: AppModel) {
        let isNew = self.panel == nil
        let panel = self.panel ?? makePanel(session: session, app: app)
        self.panel = panel
        apply(settings: app.settings, to: panel)
        // Fix a restored frame only when it was saved by the other layout (or the
        // older 420-wide build); otherwise keep the size the user chose.
        if isNew { applyLayout(compact: app.settings.compactOverlay, restoring: true) }
        panel.orderFrontRegardless()
    }

    /// Sizes the panel for the layout, keeping its top edge and the side edge
    /// nearer the screen edge (so a left-placed panel stays left), and the whole
    /// panel on screen. `restoring`: a frame just restored for a new meeting,
    /// whose width is kept unless it belongs to the other layout.
    func applyLayout(compact: Bool, restoring: Bool = false) {
        guard let panel else { return }
        let minSize = compact ? Self.compactMinSize : Self.splitMinSize
        panel.contentMinSize = minSize
        var frame = panel.frame
        let width: CGFloat
        if compact {
            width = restoring && frame.width < Self.splitMinSize.width
                ? max(frame.width, minSize.width)
                : Self.compactSize.width
        } else {
            width = restoring && frame.width >= Self.splitMinSize.width
                ? frame.width
                : max(frame.width, Self.splitSize.width)
        }
        let height = max(frame.height, minSize.height)
        guard width != frame.width || height != frame.height else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        let keepLeft = visible.map { frame.midX < $0.midX } ?? false
        frame = CGRect(x: keepLeft ? frame.minX : frame.maxX - width, y: frame.maxY - height, width: width, height: height)
        if let visible {
            frame.size.width = min(frame.width, visible.width)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    func toggle(session: MeetingSession, app: AppModel) {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            show(session: session, app: app)
        }
    }

    /// Hides the overlay; the meeting keeps running. The hotkey or the menu bar brings it back.
    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Makes the panel key so the Steer field can take typing.
    func focusForTyping(session: MeetingSession, app: AppModel) {
        show(session: session, app: app)
        panel?.makeKey()
    }

    /// Makes the visible panel key, so a click on the Steer box can take typing.
    func makeKeyForTyping() {
        panel?.makeKey()
    }

    /// Hands the keyboard back to the meeting app after typing in the overlay.
    func releaseFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func apply(settings: AppSettings, to panel: NSPanel? = nil) {
        guard let panel = panel ?? self.panel else { return }
        // Apple now treats `.none` as legacy and ScreenCaptureKit-based sharing
        // may still capture the window. It's kept because some apps honor it.
        panel.sharingType = settings.hideFromScreenSharing ? .none : .readOnly
    }

    func moveToCorner(_ corner: AppSettings.OverlayCorner) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, corner: corner, in: screen.visibleFrame))
        panel.saveFrame(usingName: Self.autosaveName)
    }

    private func makePanel(session: MeetingSession, app: AppModel) -> OverlayPanel {
        let size = app.settings.compactOverlay ? Self.compactSize : Self.splitSize
        let panel = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "VibeMeeting"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Always dark glass, so it reads the same over any meeting app.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onZoom = { [weak app] in
            app?.settings.compactOverlay.toggle()
        }
        panel.contentMinSize = app.settings.compactOverlay ? Self.compactMinSize : Self.splitMinSize

        let root = OverlayView(controller: self)
            .environment(app)
            .environment(session)
            .tint(Brand.accent)
        panel.contentView = NSHostingView(rootView: root)

        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main {
            panel.setFrameOrigin(Self.origin(for: size, corner: app.settings.overlayCorner, in: screen.visibleFrame))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    static func origin(for size: CGSize, corner: AppSettings.OverlayCorner, in frame: CGRect) -> CGPoint {
        let margin: CGFloat = 16
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case .topRight: return CGPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomLeft: return CGPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomRight: return CGPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
    }
}
