import AppKit
import KeyboardShortcuts
import SwiftUI
import VibeCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfileSettings()
                .tabItem { Label("About me", systemImage: "person.crop.circle") }
            PresetSettings()
                .tabItem { Label("Reply styles", systemImage: "text.quote") }
            HotkeySettings()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "waveform") }
            OverlaySettings()
                .tabItem { Label("Overlay", systemImage: "macwindow") }
        }
        .padding(20)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                SecureField("Claude API key", text: $keyDraft, prompt: Text(settings.hasAPIKey ? "Saved in Keychain" : "sk-ant-…"))
                HStack {
                    Button("Save key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test connection") { Task { await test() } }
                        .disabled(!settings.hasAPIKey || testing)
                    if settings.hasAPIKey {
                        Button("Remove", role: .destructive) {
                            try? settings.setAPIKey("")
                            keyMessage = "Key removed."
                        }
                    }
                    if testing { ProgressView().controlSize(.small) }
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Claude API")
            } footer: {
                Text("Stored in your Keychain. Only text (recent transcript, context, instructions) is sent to Claude. Audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                ModelPicker(title: "Replies", selection: $settings.replyModelID)
                Text("Replies need the fastest first word. Claude Haiku 5.5 runs with thinking off; Opus 5.5 can't turn thinking off and runs at low effort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModelPicker(title: "Recap", selection: $settings.recapModelID)
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        do {
            try app.settings.setAPIKey(keyDraft)
            keyDraft = ""
            keyMessage = "Saved in Keychain."
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let client = ClaudeClient(apiKey: app.settings.apiKey, transport: app.transport)
        let probe = MessagesRequest(
            model: app.settings.replyModelID,
            maxTokens: 0,
            system: [],
            messages: [.user([.text("ping")])]
        )
        do {
            try await client.warm(probe)
            keyMessage = "Connected to \(app.settings.replyModel.displayName)."
        } catch {
            keyMessage = error.localizedDescription
        }
    }
}

private struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    @State private var editingCustom = false

    var body: some View {
        let isCustom = !ClaudeModel.catalog.contains { $0.id == selection }
        Picker(title, selection: Binding(
            get: { (isCustom || editingCustom) ? "custom" : selection },
            set: { value in
                if value == "custom" {
                    editingCustom = true
                } else {
                    editingCustom = false
                    selection = value
                }
            }
        )) {
            ForEach(ClaudeModel.catalog) { model in
                Text(model.displayName).tag(model.id)
            }
            Text("Custom model ID…").tag("custom")
        }
        if isCustom || editingCustom {
            TextField("Model ID", text: Binding(
                get: { isCustom ? selection : "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { selection = trimmed }
                }
            ))
        }
    }
}

// MARK: - About me

private struct ProfileSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 8) {
            Text("About me")
                .font(.headline)
            Text("Sent with every reply: who you are, your brand, stack, portfolio, and your rules for scope and pricing. Numbers in replies only ever come from here or the meeting context.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $settings.aboutMe)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Text("≈ \(TokenEstimator.tokens(forText: settings.aboutMe).formatted()) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to template") { settings.aboutMe = Prompts.aboutMeTemplate }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Presets

private struct PresetSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selectedID: String?

    var body: some View {
        @Bindable var settings = app.settings
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selectedID) {
                    Section("Built in") {
                        ForEach(StylePreset.builtIns) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    Section("Yours") {
                        ForEach(settings.customPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
                .frame(width: 190)
                HStack {
                    Button {
                        let preset = StylePreset(name: "New style", instructions: "", minSentences: 2, maxSentences: 4)
                        settings.customPresets.append(preset)
                        selectedID = preset.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        guard let selectedID else { return }
                        settings.customPresets.removeAll { $0.id == selectedID }
                        if settings.defaultPresetID == selectedID { settings.defaultPresetID = StylePreset.friendlyProID }
                        self.selectedID = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(!isCustom(selectedID))
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("Default style", selection: $settings.defaultPresetID) {
                    ForEach(settings.allPresets) { Text($0.name).tag($0.id) }
                }
                Divider()
                if let selectedID, let index = settings.customPresets.firstIndex(where: { $0.id == selectedID }) {
                    CustomPresetEditor(preset: $settings.customPresets[index])
                } else if let selectedID, let preset = StylePreset.builtIns.first(where: { $0.id == selectedID }) {
                    Text(preset.name).font(.headline)
                    Text(preset.lengthDescription).font(.caption).foregroundStyle(.secondary)
                    Text(preset.instructions)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Duplicate to edit") {
                        var copy = preset
                        copy.id = UUID().uuidString
                        copy.name = "\(preset.name) (mine)"
                        copy.isBuiltIn = false
                        settings.customPresets.append(copy)
                        self.selectedID = copy.id
                    }
                    Spacer()
                } else {
                    Text("Select a style to view or edit it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isCustom(_ id: String?) -> Bool {
        guard let id else { return false }
        return app.settings.customPresets.contains { $0.id == id }
    }
}

private struct CustomPresetEditor: View {
    @Binding var preset: StylePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $preset.name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Stepper("At least \(preset.minSentences) sentence\(preset.minSentences == 1 ? "" : "s")", value: Binding(
                    get: { preset.minSentences },
                    set: { preset.minSentences = $0; preset.maxSentences = max(preset.maxSentences, $0) }
                ), in: 1...8)
                Stepper("at most \(preset.maxSentences)", value: Binding(
                    get: { preset.maxSentences },
                    set: { preset.maxSentences = max($0, preset.minSentences) }
                ), in: 1...10)
            }
            Text("Instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $preset.instructions)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

// MARK: - Hotkeys

private struct HotkeySettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(Hotkeys.entries) { entry in
                    LabeledContent {
                        KeyboardShortcuts.Recorder(for: entry.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                            Text(entry.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Hotkeys only work while a meeting is running. If an ⌥ + letter hotkey sometimes types a character instead of firing, switch it to ⌃⌥ + letter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

private struct AudioSettings: View {
    @Environment(AppModel.self) private var app
    @State private var apps: [AudioProcessCatalog.AudioApp] = []
    @State private var priming = false
    @State private var primeMessage: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Listen to", selection: $settings.audioSourceBundleID) {
                    Text("All system audio").tag(String?.none)
                    ForEach(apps) { audioApp in
                        Text(audioApp.isPlaying ? "\(audioApp.name) (playing)" : audioApp.name)
                            .tag(String?.some(audioApp.bundleID))
                    }
                    if let current = settings.audioSourceBundleID, !apps.contains(where: { $0.bundleID == current }) {
                        Text(current).tag(String?.some(current))
                    }
                }
                Button("Refresh app list") { apps = AudioProcessCatalog.apps() }
                    .controlSize(.small)
            } header: {
                Text("Other side")
            } footer: {
                Text("All system audio works with any call app. Pick one app to ignore music or notifications; for Safari calls keep All system audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Echo cancellation", isOn: $settings.voiceProcessing)
                Text("Keeps the other side's voice from the speakers out of your mic. macOS may lower other apps' volume a little while it's on. With a headset you can turn it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Your mic")
            }

            Section("Permissions") {
                LabeledContent("System audio permission", value: SystemAudioPermission.status.rawValue)
                HStack {
                    Button("Allow audio capture") { Task { await prime() } }
                        .disabled(priming)
                    if priming { ProgressView().controlSize(.small) }
                }
                if let primeMessage {
                    Text(primeMessage).font(.caption).foregroundStyle(.secondary)
                }
                Button("Open Audio check…") { app.windows.showAudioCheck() }
                    .controlSize(.small)
                Button("Open Privacy & Security settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { apps = AudioProcessCatalog.apps() }
    }

    private func prime() async {
        priming = true
        defer { priming = false }
        let result = await PermissionPrimer.run()
        primeMessage = result.summary
    }
}

// MARK: - Overlay

private struct OverlaySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Position") {
                Picker("Corner", selection: $settings.overlayCorner) {
                    ForEach(AppSettings.OverlayCorner.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.overlayCorner) { _, corner in
                    app.overlay.moveToCorner(corner)
                }
                Text("You can also drag the overlay anywhere and resize it; it remembers where you put it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Look") {
                Slider(value: $settings.overlayOpacity, in: 0.4...1) {
                    Text("Background opacity")
                }
                Toggle("Compact mode (last two turns and the script)", isOn: $settings.compactOverlay)
            }
            Section {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenSharing)
                    .onChange(of: settings.hideFromScreenSharing) {
                        app.overlay.apply(settings: app.settings)
                    }
            } footer: {
                Text("Recent macOS versions let many screen-sharing apps capture the overlay anyway. Before you share your screen, hide it with \(Hotkeys.label(.toggleOverlay)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
