import AppKit
import SwiftUI

/// Floating, always-on-top panel that never steals focus from the meeting app.
final class OverlayPanel: NSPanel {
    // Lets the Steer field and transcript edits take typing without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private var panel: OverlayPanel?

    static let autosaveName = "VibeMeetingOverlay"

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: MeetingSession, app: AppModel) {
        let panel = self.panel ?? makePanel(session: session, app: app)
        self.panel = panel
        apply(settings: app.settings, to: panel)
        panel.orderFrontRegardless()
    }

    func toggle(session: MeetingSession, app: AppModel) {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            show(session: session, app: app)
        }
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
        let size = CGSize(width: 420, height: 560)
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
        panel.contentMinSize = CGSize(width: 340, height: 260)

        let root = OverlayView(controller: self)
            .environment(app)
            .environment(session)
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
