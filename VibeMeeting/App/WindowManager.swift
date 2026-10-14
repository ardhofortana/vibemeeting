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
    private let settingsNavigation = SettingsNavigation()

    init(app: AppModel) {
        self.app = app
    }

    /// `takeFocus` false shows it in front without taking the keyboard from
    /// the app in use, for when it opens on its own (after a meeting is saved).
    func showMain(takeFocus: Bool = true) {
        show(id: "main", title: "VibeMeeting", size: CGSize(width: 980, height: 680), minSize: CGSize(width: 760, height: 500), glass: true, takeFocus: takeFocus) {
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

    /// Opens Settings, on `tab` if given, else where it was left.
    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsNavigation.tab = tab }
        show(id: "settings", title: "Settings", size: CGSize(width: 680, height: 560), minSize: CGSize(width: 620, height: 480)) {
            SettingsView(navigation: settingsNavigation)
        }
    }

    func showAudioCheck() {
        show(id: "audio-check", title: "Audio check", size: CGSize(width: 720, height: 560), minSize: CGSize(width: 620, height: 480)) {
            AudioCheckView()
        }
    }

    func showWelcome() {
        show(id: "welcome", title: "Welcome to VibeMeeting", size: CGSize(width: 520, height: 660), minSize: CGSize(width: 480, height: 600)) {
            WelcomeView()
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    /// `title` is localized; glass windows hide it but Mission Control and the Window menu show it.
    private func show<Content: View>(
        id: String,
        title: LocalizedStringResource,
        size: CGSize,
        minSize: CGSize,
        glass: Bool = false,
        takeFocus: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        if let window = windows[id] {
            present(window, takeFocus: takeFocus)
            return
        }
        let chrome = WindowChromeModel()
        let controller = NSHostingController(rootView: GlassRoot(chrome: chrome, glass: glass, content: content()).environment(app).tint(Brand.accent))
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: title)
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
        // Opens on the Space the user is on, not the one it was last shown on.
        window.collectionBehavior.insert(.moveToActiveSpace)
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
        present(window, takeFocus: takeFocus)
    }

    /// Brings `window` in front of every app's windows. VibeMeeting isn't the
    /// active app when its menu bar menu is used, and since macOS 14
    /// `NSApp.activate()` is only a request the system often declines for a menu
    /// bar app, so windows opened behind the app in front (FB23508310).
    private func present(_ window: NSWindow, takeFocus: Bool) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Dock icon first: activating before the switch leaves the other app's
        // menus in the menu bar. windowWillClose switches back.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        raise(window, takeFocus: takeFocus)
        // The menu closing and the switch to .regular settle over the next
        // moments, and the first request can be declined: ask again until the
        // window is key.
        for delay in [100, 350] {
            Task { [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, let window, window.isVisible, !(NSApp.isActive && window.isKeyWindow) else { return }
                self.raise(window, takeFocus: takeFocus)
            }
        }
    }

    private func raise(_ window: NSWindow, takeFocus: Bool) {
        // Key first, so activation brings this window forward, not another of ours.
        window.makeKeyAndOrderFront(nil)
        // In front of other apps' windows even if activation is declined.
        window.orderFrontRegardless()
        guard takeFocus else {
            NSApp.activate()
            return
        }
        // Take activation from the app in front, the non-deprecated way.
        let me = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me.processIdentifier {
            _ = me.activate(from: front, options: [])
        }
        // Deprecated since macOS 14 (Apple says the flag is ignored), but it is
        // what still brings a menu bar app forward after a click in its menu
        // (Electron, Rectangle and others ship it); a no-op once active.
        NSApp.activate(ignoringOtherApps: true)
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
