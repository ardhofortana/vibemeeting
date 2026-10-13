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
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, goal, instructions
    }

    private static let goalLimit = 500
    private static let instructionsLimit = 300

    var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "New Meeting")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New meeting")
                            .font(.system(size: 24, weight: .bold))
                        Text("Set up your context and preferences before you start.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    nameField
                    goalSection
                    contextSection
                    replyStyleSection

                    if CodeSigning.isAdHoc {
                        GlassNotice(
                            text: "This build has no signing Team, so macOS may give it only silence from the call. Pick your Team in Xcode and run scripts/save-signing-team.sh (see the README).",
                            systemImage: "exclamationmark.triangle.fill",
                            action: "Open Audio check"
                        ) { app.windows.showAudioCheck() }
                    }

                    if !app.settings.hasAPIKey {
                        GlassNotice(
                            text: "No Claude API key yet. Subtitles will work, but replies need a key.",
                            systemImage: "key.fill",
                            action: "Open Settings"
                        ) { app.windows.showSettings(tab: .general) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }

            footer
        }
        .ignoresSafeArea(.container, edges: .top)
        .defaultFocus($focus, .name)
        .onChange(of: goal) { _, value in
            if value.count > Self.goalLimit { goal = String(value.prefix(Self.goalLimit)) }
        }
        .onChange(of: instructions) { _, value in
            if value.count > Self.instructionsLimit { instructions = String(value.prefix(Self.instructionsLimit)) }
        }
    }

    private var nameField: some View {
        HStack(spacing: 12) {
            Text("T")
                .font(.system(size: 18, design: .serif))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            TextField("Meeting name (optional)", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focus, equals: .name)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .glassField(focused: focus == .name)
        .contentShape(Rectangle())
        .onTapGesture { focus = .name }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "Goal", systemImage: "target")
            TextField(
                "What do you want from this call? e.g. Agree on the scope of milestone 1 and get a go-ahead for the proposal.",
                text: $goal,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(2...5)
            .focused($focus, equals: .goal)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .glassField(focused: focus == .goal)
            .contentShape(Rectangle())
            .onTapGesture { focus = .goal }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Replies and Ask questions steer toward it, and the recap says how far you got. Optional; you can change it during the call.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                counter(goal, limit: Self.goalLimit)
            }
            .padding(.horizontal, 2)
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "Context", systemImage: "paperclip") {
                Label("The more context, the better responses.", systemImage: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ContextEditor(items: $items, notes: $notes)
        }
    }

    private var replyStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title: "Reply style", systemImage: "slider.horizontal.3") {
                Button {
                    app.windows.showSettings(tab: .replyStyles)
                } label: {
                    Label("Manage styles", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Brand.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add or edit reply styles in Settings")
            }
            presetMenu
            instructionsField
        }
    }

    private var presetMenu: some View {
        let selected = app.settings.preset(id: presetBinding.wrappedValue)
        return Menu {
            ForEach(app.settings.allPresets) { preset in
                Button {
                    presetID = preset.id
                } label: {
                    if preset.id == selected.id {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            PresetCard(preset: selected)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help("Reply style")
    }

    private var instructionsField: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.gradient(startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20)
                TextField(
                    "Anything specific for this call? e.g. Keep pricing vague until scope is clear.",
                    text: $instructions,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($focus, equals: .instructions)
            }
            counter(instructions, limit: Self.instructionsLimit)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 7)
        .glassField(focused: focus == .instructions)
        .contentShape(Rectangle())
        .onTapGesture { focus = .instructions }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                app.windows.close("new-meeting")
            } label: {
                Text("Cancel").padding(.horizontal, 10)
            }
            .buttonStyle(GlassButtonStyle(minHeight: 42))
            .fixedSize()
            .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            if app.activeSession?.isActive == true {
                Text("This ends the meeting in progress.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                start()
            } label: {
                HStack(spacing: 10) {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Start listening")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(PrimaryGradientButtonStyle(minHeight: 42))
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(starting)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func counter(_ text: String, limit: Int) -> some View {
        Text("\(text.count)/\(limit)")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(text.count >= limit ? Color.orange : Color.secondary)
            .fixedSize()
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { presetID ?? app.settings.defaultPresetID },
            set: { presetID = $0 }
        )
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

/// The chosen reply style: the logo, its name and what it sounds like.
private struct PresetCard: View {
    let preset: StylePreset
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.fieldRadius, style: .continuous)
        HStack(spacing: 14) {
            LogoMark(height: 26)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Glass.fieldHoverFill : Glass.fieldFill, in: shape)
        .overlay(shape.strokeBorder(Glass.fieldStroke))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }

    /// The first sentence of the style's instructions, or its length when it has none.
    private var summary: String {
        let instructions = preset.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var first = ""
        instructions.enumerateSubstrings(in: instructions.startIndex..., options: .bySentences) { sentence, _, _, stop in
            first = sentence ?? ""
            stop = true
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.lengthDescription : trimmed
    }
}

/// A warning on glass with a button that fixes it.
private struct GlassNotice: View {
    let text: String
    let systemImage: String
    let action: String
    let perform: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action, action: perform)
                    .buttonStyle(GlassButtonStyle(minHeight: 28))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(Color.orange.opacity(0.3)))
    }
}

/// Adds context while a meeting is running.
struct AddContextView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [ContextItem] = []
    @State private var notes = ""

    var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "Meeting context")
            if let session = app.activeSession, session.isActive {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Add context")
                                .font(.system(size: 24, weight: .bold))
                            Text("Added items are used from the next reply on.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ContextEditor(
                            items: $items,
                            notes: $notes,
                            onAdd: { session.addContext($0) },
                            onRemove: { session.removeContext($0) }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
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
                    .buttonStyle(PrimaryGradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            } else {
                ContentUnavailableView("No meeting in progress", systemImage: "waveform.slash", description: Text("Start a meeting to add context."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        // The window is reused, so reload whenever the meeting changes.
        .task(id: app.activeSession?.id) {
            items = app.activeSession?.record.context ?? []
            notes = ""
        }
    }
}
