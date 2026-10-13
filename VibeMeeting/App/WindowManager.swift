import AppKit
import Observation
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
        show(id: "main", title: "VibeMeeting", size: CGSize(width: 980, height: 680), minSize: CGSize(width: 760, height: 500), glass: true) {
            MainWindowView()
        }
    }

    func showNewMeeting() {
        show(id: "new-meeting", title: "New meeting", size: CGSize(width: 640, height: 820), minSize: CGSize(width: 520, height: 560), glass: true) {
            NewMeetingView()
        }
    }

    func showAddContext() {
        show(id: "add-context", title: "Meeting context", size: CGSize(width: 560, height: 600), minSize: CGSize(width: 460, height: 440), glass: true) {
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
        glass: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let chrome = WindowChromeModel()
        let controller = NSHostingController(rootView: GlassRoot(chrome: chrome, glass: glass, content: content()).environment(app).tint(Brand.accent))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        if glass {
            // Dark glass: the SwiftUI view draws the whole window, title row included,
            // under a transparent title bar; the system buttons stay where they are.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = .clear
        }
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
        if glass {
            chrome.update(from: window)
        }
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

/// Measures where a glass window's title bar and buttons are, for `WindowTitleBar`.
@MainActor
@Observable
final class WindowChromeModel {
    var value = WindowChrome()

    func update(from window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let titleBarHeight = contentView.bounds.height - window.contentLayoutRect.height
        var inset = value.leadingInset
        if let zoom = window.standardWindowButton(.zoomButton), zoom.superview != nil {
            inset = zoom.convert(zoom.bounds, to: nil).maxX + 14
        }
        value = WindowChrome(titleBarHeight: max(titleBarHeight, 28), leadingInset: inset)
    }
}

/// Puts a glass window's content on the glass and hands it the measured title bar geometry.
private struct GlassRoot<Content: View>: View {
    let chrome: WindowChromeModel
    let glass: Bool
    let content: Content

    var body: some View {
        content
            .environment(\.windowChrome, chrome.value)
            .background {
                if glass {
                    GlassBackground()
                }
            }
    }
}
