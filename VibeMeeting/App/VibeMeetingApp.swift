import AppKit
import SwiftUI

@main
struct VibeMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appDelegate.app)
        } label: {
            MenuBarIcon()
                .environment(appDelegate.app)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        app.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        app.isTerminating = true
        // Still set while a meeting is ending, so Quit waits for its save too.
        guard app.activeSession != nil else { return .terminateNow }
        // Save the transcript before quitting mid-meeting.
        Task {
            await app.endMeeting(thenRecap: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.windows.showMain() }
        return true
    }
}

private struct MenuBarIcon: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // Template images from the logo's bars, tinted by the menu bar.
        if app.activeSession?.isActive == true {
            Image("MenuBarLive")
        } else {
            Image("MenuBarIdle")
        }
    }
}

private struct MenuContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let session = app.activeSession, session.isActive {
            Text("\(session.record.displayName) · \(session.status.label)")
            Button("Show/hide overlay") { app.toggleOverlay() }
            Button("Add context…") { app.windows.showAddContext() }
            Button("End meeting") {
                Task { await app.endMeeting() }
            }
            Divider()
        } else {
            if let session = app.activeSession {
                Text("Saving \(session.record.displayName)…")
            }
            Button("New meeting") { app.windows.showNewMeeting() }
                .keyboardShortcut("n")
        }
        Button("Open VibeMeeting") { app.windows.showMain() }
            .keyboardShortcut("o")
        Button("Audio check…") { app.windows.showAudioCheck() }
        Button("Settings…") { app.windows.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Text("\(AppIdentity.displayName) \(AppVersion.display)")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
