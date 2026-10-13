import Foundation
import KeyboardShortcuts
import VibeCore

@MainActor
extension KeyboardShortcuts.Name {
    static let reply = Self("reply", default: .init(.space, modifiers: [.option]))
    static let answer = Self("answer", default: .init(.one, modifiers: [.option]))
    static let clarify = Self("clarify", default: .init(.two, modifiers: [.option]))
    static let add = Self("add", default: .init(.three, modifiers: [.option]))
    static let pushBack = Self("pushBack", default: .init(.four, modifiers: [.option]))
    static let steer = Self("steer", default: .init(.space, modifiers: [.option, .shift]))
    static let regenerate = Self("regenerate", default: .init(.r, modifiers: [.option]))
    static let shorter = Self("shorter", default: .init(.s, modifiers: [.option]))
    static let askQuestions = Self("askQuestions", default: .init(.q, modifiers: [.option]))
    static let toggleOverlay = Self("toggleOverlay", default: .init(.h, modifiers: [.option]))
}

/// Global hotkeys. They are only active during a meeting, so ⌥Space and
/// friends keep working normally in other apps the rest of the time.
@MainActor
enum Hotkeys {
    /// A hotkey as Settings lists it. Title and note are localized.
    struct Entry: Identifiable {
        let name: KeyboardShortcuts.Name
        let title: LocalizedStringResource
        let note: LocalizedStringResource
        var id: String { name.rawValue }
    }

    static let entries: [Entry] = [
        Entry(name: .reply, title: "Reply (Auto)", note: "Main action; Claude picks the best move"),
        Entry(name: .answer, title: "Answer", note: "Answer the question"),
        Entry(name: .clarify, title: "Clarify", note: "Correct politely or ask back"),
        Entry(name: .add, title: "Add", note: "Add a point"),
        Entry(name: .pushBack, title: "Push back", note: "Disagree politely"),
        Entry(name: .steer, title: "Steer", note: "Focus the steer field; Enter to generate"),
        Entry(name: .regenerate, title: "Regenerate", note: "New script for the same target"),
        Entry(name: .shorter, title: "Shorter", note: "Shorten the last script"),
        Entry(name: .askQuestions, title: "Ask questions", note: "Questions to ask them, toward the meeting goal"),
        Entry(name: .toggleOverlay, title: "Show/hide overlay", note: "Hide without stopping the meeting"),
    ]

    static var names: [KeyboardShortcuts.Name] { entries.map(\.name) }

    /// The UserDefaults keys KeyboardShortcuts saves these hotkeys under. Literal
    /// names, so reading them doesn't create the names: creating one stores its
    /// default and registers it system-wide when nothing is stored yet.
    static let storageKeys = ["reply", "answer", "clarify", "add", "pushBack", "steer", "regenerate", "shorter", "askQuestions", "toggleOverlay"]
        .map { "KeyboardShortcuts_\($0)" }

    static func install(app: AppModel) {
        assert(Set(storageKeys) == Set(names.map { "KeyboardShortcuts_\($0.rawValue)" }), "storageKeys must list every hotkey")
        KeyboardShortcuts.onKeyDown(for: .reply) { [weak app] in app?.activeSession?.reply() }
        KeyboardShortcuts.onKeyDown(for: .answer) { [weak app] in app?.activeSession?.reply(intent: .answer) }
        KeyboardShortcuts.onKeyDown(for: .clarify) { [weak app] in app?.activeSession?.reply(intent: .clarify) }
        KeyboardShortcuts.onKeyDown(for: .add) { [weak app] in app?.activeSession?.reply(intent: .add) }
        KeyboardShortcuts.onKeyDown(for: .pushBack) { [weak app] in app?.activeSession?.reply(intent: .pushBack) }
        KeyboardShortcuts.onKeyDown(for: .regenerate) { [weak app] in app?.activeSession?.regenerate() }
        KeyboardShortcuts.onKeyDown(for: .shorter) { [weak app] in app?.activeSession?.shorter() }
        KeyboardShortcuts.onKeyDown(for: .askQuestions) { [weak app] in app?.activeSession?.askQuestions() }
        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) { [weak app] in app?.toggleOverlay() }
        KeyboardShortcuts.onKeyDown(for: .steer) { [weak app] in
            guard let app, let session = app.activeSession else { return }
            app.overlay.focusForTyping(session: session, app: app)
            session.requestSteerFocus()
        }
        setEnabled(false)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(names)
        } else {
            KeyboardShortcuts.disable(names)
        }
    }

    /// Short label for a hotkey, e.g. "⌥Space", for hints in the UI.
    static func label(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name).map { "\($0)" } ?? "–"
    }

    /// Two hotkeys as a range, e.g. "⌥1–4" when both use the same modifiers.
    static func rangeLabel(_ first: KeyboardShortcuts.Name, _ last: KeyboardShortcuts.Name) -> String {
        let start = label(first)
        let end = label(last)
        let modifiers = String(start.prefix { "⌃⌥⇧⌘".contains($0) })
        if !modifiers.isEmpty, end.hasPrefix(modifiers), end.count > modifiers.count,
           !"⌃⌥⇧⌘".contains(end[end.index(end.startIndex, offsetBy: modifiers.count)]) {
            return start + "–" + String(end.dropFirst(modifiers.count))
        }
        return start + "–" + end
    }
}
