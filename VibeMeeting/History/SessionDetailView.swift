import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// One saved meeting: recap, transcript, scripts, and context.
struct SessionDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case recap = "Recap"
        case transcript = "Transcript"
        case scripts = "Scripts"
        case context = "Context"
        var id: String { rawValue }
    }

    let recordID: UUID
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .recap
    @State private var confirmingDelete = false
    @State private var editingName = false
    @State private var draftName = ""

    var body: some View {
        if let record = app.record(id: recordID) {
            VStack(alignment: .leading, spacing: 0) {
                header(record)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                Divider()
                content(record)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .toolbar {
                ToolbarItem {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete this meeting permanently")
                    .disabled(isLive)
                }
            }
            .confirmationDialog("Delete “\(record.displayName)” permanently?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { app.delete(id: recordID) }
            } message: {
                Text("The transcript, scripts, context and recap are removed from this Mac. This can't be undone.")
            }
        }
    }

    /// In progress or still saving: the stored record isn't final yet.
    private var isLive: Bool {
        app.activeSession?.id == recordID
    }

    // MARK: - Header

    private func header(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editingName {
                TextField("Meeting name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .onSubmit {
                        app.rename(id: recordID, to: draftName)
                        editingName = false
                    }
                    .onExitCommand { editingName = false }
            } else {
                Text(record.displayName)
                    .font(.title2.weight(.semibold))
                    .onTapGesture(count: 2) {
                        guard !isLive else { return }
                        draftName = record.name
                        editingName = true
                    }
                    .help("Double-click to rename")
            }
            Text(metaLine(record))
                .font(.callout)
                .foregroundStyle(.secondary)
            if !record.goal.isEmpty {
                Label(record.goal, systemImage: "target")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(statsLine(record))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metaLine(_ record: MeetingRecord) -> String {
        var parts = [record.startedAt.formatted(date: .complete, time: .shortened)]
        if let duration = record.duration { parts.append(Recap.formatDuration(duration)) }
        parts.append(record.presetName)
        if isLive { parts.append(app.activeSession?.isActive == true ? "In progress" : "Saving…") }
        return parts.joined(separator: " · ")
    }

    private func statsLine(_ record: MeetingRecord) -> String {
        let stats = record.stats
        var parts = ["\(stats.replyCount) repl\(stats.replyCount == 1 ? "y" : "ies")"]
        if let rate = stats.regenerateRate {
            parts.append("regenerated \(Int((rate * 100).rounded()))%")
        }
        if let median = stats.medianFirstTokenLatency {
            parts.append(String(format: "first word %.1fs median", median))
        }
        if let p90 = stats.p90FirstTokenLatency, stats.firstTokenLatencies.count >= 5 {
            parts.append(String(format: "%.1fs p90", p90))
        }
        if stats.estimatedCost > 0 {
            parts.append(String(format: "≈ $%.3f", stats.estimatedCost))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tabs

    @ViewBuilder
    private func content(_ record: MeetingRecord) -> some View {
        switch tab {
        case .recap:
            recapTab(record)
        case .transcript:
            transcriptTab(record)
        case .scripts:
            scriptsTab(record)
        case .context:
            contextTab(record)
        }
    }

    @ViewBuilder
    private func recapTab(_ record: MeetingRecord) -> some View {
        if app.recapsInProgress.contains(record.id) {
            VStack(spacing: 10) {
                ProgressView()
                Text("Writing the recap…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let recap = record.recap {
            RecapView(recap: recap, record: record) {
                Task { await app.generateRecap(for: record.id) }
            }
        } else if isLive {
            ContentUnavailableView("Meeting in progress", systemImage: "waveform", description: Text("The recap is created when you end the meeting."))
        } else {
            VStack(spacing: 12) {
                if let error = record.recapError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Button(record.recapError == nil ? "Create recap" : "Try again") {
                    Task { await app.generateRecap(for: record.id) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptTab(_ record: MeetingRecord) -> some View {
        let turns = isLive ? (app.activeSession?.transcript.turns ?? record.turns) : record.turns
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button("Copy transcript") {
                    copy(record.transcriptText())
                }
                .controlSize(.small)
                .disabled(turns.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if turns.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.bubble")
            } else {
                List(turns) { turn in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(MeetingRecord.offset(turn.startedAt.timeIntervalSince(record.startedAt)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 56, alignment: .leading)
                        Text(turn.speaker.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(turn.speaker == .them ? Color.accentColor : Color.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(turn.text)
                            .textSelection(.enabled)
                            .foregroundStyle(turn.speaker == .them ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    }
                }
            }
        }
    }

    private func scriptsTab(_ record: MeetingRecord) -> some View {
        Group {
            if record.scripts.isEmpty {
                ContentUnavailableView("No scripts", systemImage: "text.quote", description: Text("Scripts appear here after you press Reply."))
            } else {
                List(record.scripts.reversed()) { script in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(script.targetText)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(ScriptText.sanitize(script.text))
                            .textSelection(.enabled)
                        Text(scriptMeta(script))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Copy") { copy(ScriptText.sanitize(script.text)) }
                    }
                }
            }
        }
    }

    private func scriptMeta(_ script: ReplyScript) -> String {
        var parts = [script.createdAt.formatted(date: .omitted, time: .shortened), script.intent.label]
        if script.variant != .fresh { parts.append(script.variant == .shorter ? "Shorter" : "Regenerated") }
        if !script.steer.isEmpty { parts.append("Steer: \(script.steer)") }
        parts.append(script.presetName)
        if let latency = script.firstTokenLatency { parts.append(String(format: "%.1fs", latency)) }
        return parts.joined(separator: " · ")
    }

    private func contextTab(_ record: MeetingRecord) -> some View {
        Group {
            if record.context.isEmpty && record.meetingInstructions.isEmpty {
                ContentUnavailableView("No context", systemImage: "doc.text")
            } else {
                List {
                    if !record.meetingInstructions.isEmpty {
                        Section("Instructions for this call") {
                            Text(record.meetingInstructions).textSelection(.enabled)
                        }
                    }
                    Section("Context") {
                        ForEach(record.context) { item in
                            DisclosureGroup(item.title) {
                                switch item.content {
                                case .text(let text):
                                    Text(text)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                case .image(let data, _, _, _):
                                    if let image = NSImage(data: data) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 320)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The recap with Copy as Markdown and .md export.
struct RecapView: View {
    let recap: Recap
    let record: MeetingRecord
    let regenerate: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Meeting recap").font(.title3.weight(.semibold))
                    Spacer()
                    Button(copied ? "Copied" : "Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        copied = true
                    }
                    Button("Export .md…") { export() }
                    Menu {
                        Button("Create again", action: regenerate)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)

                if !record.goal.isEmpty {
                    section("Goal") {
                        Text(record.goal).foregroundStyle(.secondary).textSelection(.enabled)
                        if !recap.goalProgress.isEmpty {
                            Text(recap.goalProgress).textSelection(.enabled)
                        }
                    }
                }
                section("Summary") {
                    Text(recap.summary).textSelection(.enabled)
                }
                bulletSection("Key points", recap.keyPoints)
                bulletSection("Decisions", recap.decisions)
                section("Action items") {
                    if recap.actionItems.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(recap.actionItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task).textSelection(.enabled)
                                Text(item.due.isEmpty ? item.owner.label : "\(item.owner.label) · due \(item.due)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                bulletSection("Open questions", recap.openQuestions)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var markdown: String {
        recap.markdown(title: record.displayName, date: record.startedAt, duration: record.duration, goal: record.goal)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bulletSection(_ title: String, _ items: [String]) -> some View {
        section(title) {
            if items.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(record.displayName).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
