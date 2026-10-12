import SwiftUI
import VibeCore

/// Quick setup right before a call: name, goal, context, reply style, instructions.
struct NewMeetingView: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var goal = ""
    @State private var items: [ContextItem] = []
    @State private var notes = ""
    @State private var presetID: String?
    @State private var instructions = ""
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("New meeting")
                        .font(.title2.weight(.semibold))

                    TextField("Meeting name (optional)", text: $name)
                        .textFieldStyle(.roundedBorder)

                    section("Goal") {
                        TextField(
                            "What do you want from this call? e.g. Agree on the scope of milestone 1 and get a go-ahead for the proposal.",
                            text: $goal,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        Text("Replies and Ask questions steer toward it, and the recap says how far you got. Optional; you can change it during the call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("Context") {
                        ContextEditor(items: $items, notes: $notes)
                    }

                    section("Reply style") {
                        Picker("Reply style", selection: presetBinding) {
                            ForEach(app.settings.allPresets) { preset in
                                Text("\(preset.name) · \(preset.lengthDescription)").tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        Text(app.settings.preset(id: presetBinding.wrappedValue).instructions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(
                            "Anything specific for this call? e.g. Keep pricing vague until scope is clear.",
                            text: $instructions,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    }

                    if CodeSigning.isAdHoc {
                        Label("This build has no signing Team, so macOS may give it only silence from the call. Pick your Team in Xcode and run scripts/save-signing-team.sh (see the README).", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Audio check") { app.windows.showAudioCheck() }
                            .controlSize(.small)
                    }

                    if !app.settings.hasAPIKey {
                        Label("No Claude API key yet. Subtitles will work, but replies need a key.", systemImage: "key")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button("Open Settings") { app.windows.showSettings() }
                            .controlSize(.small)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if app.activeSession?.isActive == true {
                    Text("This ends the meeting in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { app.windows.close("new-meeting") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Start listening")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(starting)
            }
            .padding(16)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { presetID ?? app.settings.defaultPresetID },
            set: { presetID = $0 }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func start() {
        starting = true
        var context = items
        let pending = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { context.append(.text(pending)) }
        let preset = app.settings.preset(id: presetBinding.wrappedValue)
        Task {
            app.windows.close("new-meeting")
            await app.startMeeting(name: name, goal: goal, context: context, preset: preset, instructions: instructions)
            // Reset for next time; the window is reused.
            name = ""
            goal = ""
            items = []
            notes = ""
            instructions = ""
            presetID = nil
            starting = false
        }
    }
}

/// Adds context while a meeting is running.
struct AddContextView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [ContextItem] = []
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = app.activeSession, session.isActive {
                Text("Meeting context")
                    .font(.title3.weight(.semibold))
                Text("Added items are used from the next reply on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    ContextEditor(
                        items: $items,
                        notes: $notes,
                        onAdd: { session.addContext($0) },
                        onRemove: { session.removeContext($0) }
                    )
                }
                HStack {
                    Spacer()
                    Button("Done") {
                        let pending = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pending.isEmpty {
                            session.addContext([.text(pending)])
                            notes = ""
                        }
                        app.windows.close("add-context")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                ContentUnavailableView("No meeting in progress", systemImage: "waveform.slash", description: Text("Start a meeting to add context."))
            }
        }
        .padding(20)
        // The window is reused, so reload whenever the meeting changes.
        .task(id: app.activeSession?.id) {
            items = app.activeSession?.record.context ?? []
            notes = ""
        }
    }
}
