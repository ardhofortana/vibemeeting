import AppKit
import SwiftUI
import VibeCore

/// The live overlay: header, goal, then the transcript and every response
/// side by side (50:50), the reply bar and hotkey hints. Compact mode stacks
/// the last subtitles and the current script in one narrow column.
struct OverlayView: View {
    let controller: OverlayController
    @Environment(AppModel.self) private var app
    @Environment(MeetingSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            // A thin line in the logo's gradient: the overlay's only large accent.
            Brand.gradient()
                .frame(height: 2)
                .opacity(0.9)
            OverlayHeader(controller: controller)
            GoalLine()
            if !session.notices.isEmpty {
                NoticeList()
            }
            if app.settings.compactOverlay {
                SubtitleListView(compact: true)
                    .frame(maxHeight: .infinity)
                ScriptCardView()
            } else {
                HStack(spacing: 0) {
                    column("Transcript") {
                        SubtitleListView(compact: false)
                    }
                    Divider()
                    column("Responses") {
                        ResponseListView()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            ReplyBar(controller: controller)
            HotkeyHints()
        }
        .onChange(of: app.settings.compactOverlay) { _, compact in
            controller.applyLayout(compact: compact)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .opacity(app.settings.overlayOpacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .ignoresSafeArea()
    }
}

extension OverlayView {
    /// One half of the split: a small title over its content, equal width.
    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

private struct OverlayHeader: View {
    let controller: OverlayController
    @Environment(AppModel.self) private var app
    @Environment(MeetingSession.self) private var session
    @State private var showingDiagnostics = false

    var body: some View {
        @Bindable var settings = app.settings
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(session.status.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Menu {
                ForEach(app.settings.allPresets) { preset in
                    Button {
                        session.setPreset(preset)
                    } label: {
                        if preset.id == session.preset.id {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Text(session.preset.name)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Reply style")

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(from: session.record.startedAt, to: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LevelMeter(level: session.themLevel, label: "Them")
            LevelMeter(level: session.youLevel, label: "You")

            Button {
                showingDiagnostics.toggle()
            } label: {
                Image(systemName: "stethoscope")
            }
            .buttonStyle(.borderless)
            .help("Audio diagnostics")
            .popover(isPresented: $showingDiagnostics) {
                DiagnosticsPanel(pipeline: session.pipeline, transcript: session.transcript)
                    .padding(14)
                    .frame(width: 600)
            }

            Button {
                app.windows.showAddContext()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .help("Add context")

            Button {
                settings.compactOverlay.toggle()
            } label: {
                Image(systemName: settings.compactOverlay ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(settings.compactOverlay ? "Transcript and responses side by side" : "Compact mode")

            Button("End meeting") {
                Task { await app.endMeeting() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var statusColor: Color {
        switch session.status {
        case .listening: return .green
        case .starting, .reconnecting: return .orange
        case .failed: return .red
        case .ending, .ended: return .gray
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }
}

private struct LevelMeter: View {
    let level: Float
    let label: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.05
                          ? AnyShapeStyle(Brand.gradient(startPoint: .bottom, endPoint: .top))
                          : AnyShapeStyle(Color.secondary))
                    .frame(height: max(2, geometry.size.height * CGFloat(level)))
            }
        }
        .frame(width: 4, height: 16)
        .help("\(label) audio level")
        .accessibilityLabel("\(label) audio level")
    }
}

// MARK: - Goal

/// The meeting goal under the header; click to set or change it.
private struct GoalLine: View {
    @Environment(MeetingSession.self) private var session
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let goal = session.record.goal
        Button {
            draft = goal
            editing = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "target")
                    .font(.caption2)
                    .foregroundStyle(goal.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.violet))
                Text(goal.isEmpty ? "Set a goal for this meeting" : goal)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(goal.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Replies and Ask questions steer toward this goal. Click to change it.")
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meeting goal").font(.headline)
                TextField("What do you want from this call?", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Text("Used from the next reply on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 340)
        }
    }

    private func save() {
        session.setGoal(draft)
        editing = false
    }
}

// MARK: - Notices

private struct NoticeList: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        VStack(spacing: 4) {
            ForEach(session.notices) { notice in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice.message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let url = notice.settingsURL {
                        Button("Open Settings") { NSWorkspace.shared.open(url) }
                            .controlSize(.mini)
                    }
                    Button {
                        session.dismissNotice(notice.kind)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Hints

private struct HotkeyHints: View {
    var body: some View {
        Text("\(Hotkeys.label(.reply)) Reply · \(Hotkeys.label(.answer))–\(Hotkeys.label(.pushBack)) Intent · \(Hotkeys.label(.askQuestions)) Questions · \(Hotkeys.label(.steer)) Steer · \(Hotkeys.label(.regenerate)) Regenerate · \(Hotkeys.label(.shorter)) Shorter · \(Hotkeys.label(.toggleOverlay)) Hide")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .padding(.top, 2)
    }
}
