import AppKit
import SwiftUI

/// Opens and reuses the app's regular windows. VibeMeeting lives in the menu
/// bar, so windows are managed here instead of through SwiftUI scenes; that
/// lets any code (hotkeys, the end of a meeting) open them.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private unowned let app: AppModel
    private var windows: [String: NSWindow] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func showMain() {
        show(id: "main", title: "VibeMeeting", size: CGSize(width: 980, height: 640), minSize: CGSize(width: 760, height: 480)) {
            MainWindowView()
        }
    }

    func showNewMeeting() {
        show(id: "new-meeting", title: "New meeting", size: CGSize(width: 560, height: 640), minSize: CGSize(width: 480, height: 520)) {
            NewMeetingView()
        }
    }

    func showAddContext() {
        show(id: "add-context", title: "Meeting context", size: CGSize(width: 520, height: 520), minSize: CGSize(width: 440, height: 400)) {
            AddContextView()
        }
    }

    func showSettings() {
        show(id: "settings", title: "Settings", size: CGSize(width: 680, height: 560), minSize: CGSize(width: 620, height: 480)) {
            SettingsView()
        }
    }

    func showAudioCheck() {
        show(id: "audio-check", title: "Audio check", size: CGSize(width: 720, height: 560), minSize: CGSize(width: 620, height: 480)) {
            AudioCheckView()
        }
    }

    func showWelcome() {
        show(id: "welcome", title: "Welcome to VibeMeeting", size: CGSize(width: 520, height: 600), minSize: CGSize(width: 480, height: 540)) {
            WelcomeView()
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    private func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        minSize: CGSize,
        @ViewBuilder content: () -> Content
    ) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content().environment(app).tint(Brand.accent))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if !window.setFrameUsingName(id) {
            window.center()
        }
        window.setFrameAutosaveName(id)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Back to a menu-bar-only app once no regular window is left.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillVisible = self.windows.values.contains { $0 !== closing && $0.isVisible }
            if !stillVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
