import AppKit
import SwiftUI
import VibeCore

/// The live overlay on dark glass: the header, then one card with the
/// transcript and every response side by side (50:50), then the reply bar.
/// Compact mode stacks the last subtitles and the current script in one
/// narrow column.
struct OverlayView: View {
    let controller: OverlayController
    @Environment(AppModel.self) private var app
    @Environment(MeetingSession.self) private var session
    @State private var width: CGFloat = 860

    var body: some View {
        let compact = app.settings.compactOverlay
        let shape = RoundedRectangle(cornerRadius: OverlayStyle.windowRadius, style: .continuous)
        VStack(spacing: 6) {
            OverlayHeader(controller: controller)
            if compact {
                GoalLine()
                    .padding(.horizontal, 10)
            }
            if !session.notices.isEmpty {
                NoticeList()
                    .padding(.horizontal, 10)
            }
            Group {
                if compact {
                    compactContent
                } else {
                    splitContent
                }
            }
            // Shrinks before the header or the reply bar would be pushed out.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous))
            .overlayCard()
            ReplyBar(controller: controller)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .environment(\.overlayDensity, OverlayDensity(width: width))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onChange(of: app.settings.compactOverlay) { _, compact in
            controller.applyLayout(compact: compact)
        }
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                Color(red: 0.035, green: 0.045, blue: 0.08).opacity(0.42)
            }
            .opacity(app.settings.overlayOpacity)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .ignoresSafeArea()
    }

    private var splitContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TranscriptHeader()
                SubtitleListView(compact: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OverlayStyle.divider
                .frame(width: 1)
                .padding(.top, 16)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ResponsesHeader()
                GoalLine()
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
                ResponseListView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            CompactStatusRow()
            SubtitleListView(compact: true)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                // Older lines are cut from the top when the script needs the room.
                .clipped()
            ScriptCardView()
                .layoutPriority(1)
        }
    }
}

// MARK: - Header

private struct OverlayHeader: View {
    let controller: OverlayController
    @Environment(AppModel.self) private var app
    @Environment(MeetingSession.self) private var session
    @Environment(\.overlayDensity) private var density
    @State private var showingDiagnostics = false

    var body: some View {
        HStack(spacing: density == .narrow ? 6 : 10) {
            OverlayWindowControls(
                isCompact: app.settings.compactOverlay,
                onHide: { controller.hide() },
                onZoom: { app.settings.compactOverlay.toggle() }
            )
            .padding(.trailing, density == .narrow ? 2 : 6)

            if density != .narrow {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            if density == .regular {
                Text("VibeMeeting")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 8)
            }

            // Gets its full width first; only the name truncates when the header runs out of room.
            presetMenu
                .layoutPriority(1)

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(from: session.record.startedAt, to: context.date))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize()
            }
            .padding(.trailing, density == .narrow ? 0 : 4)

            HStack(spacing: density == .regular ? 8 : density == .medium ? 4 : 0) {
                Button {
                    showingDiagnostics.toggle()
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(OverlayIconButtonStyle())
                .help("Audio diagnostics")
                .accessibilityLabel("Audio diagnostics")
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
                .buttonStyle(OverlayIconButtonStyle())
                .help("Add context")
                .accessibilityLabel("Add context")

                Button {
                    app.windows.showSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(OverlayIconButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            Button {
                Task { await app.endMeeting() }
            } label: {
                Text(density == .narrow ? "End" : "End meeting")
            }
            .buttonStyle(EndMeetingButtonStyle())
            .fixedSize()
            .help("End the meeting, save it and write the recap")
            .accessibilityLabel("End meeting")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var presetMenu: some View {
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
            HStack(spacing: 5) {
                Text(session.preset.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Brand.lavender)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Reply style")
    }

    /// Always hours, minutes and seconds, e.g. "00:24:17".
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Column headers

/// A column's title and subtitle (both localized), with a waveform and status on the right.
private struct ColumnHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
            }
            // The words get the room before the spacer does.
            .layoutPriority(1)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

private struct TranscriptHeader: View {
    @Environment(MeetingSession.self) private var session
    @Environment(\.overlayDensity) private var density

    var body: some View {
        let status = TranscriptStatus(session.status, modelProgress: session.speechModelProgress)
        ColumnHeader(title: "Transcript", subtitle: "Live subtitles from the meeting") {
            VStack(spacing: 6) {
                LevelWaveform(
                    read: { [session] in (them: session.themLevel, you: session.youLevel) },
                    isLive: status.isLive,
                    barCount: density == .regular ? 28 : 20
                )
                .frame(width: density == .regular ? 118 : 84, height: 30)
                // Only a problem gets a word; while listening the waveform says enough.
                if let caption = status.caption {
                    Text(caption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                }
            }
            .fixedSize()
            .help(status.help)
        }
    }
}

private struct ResponsesHeader: View {
    var body: some View {
        ColumnHeader(title: "Responses", subtitle: "AI-generated scripts based on the latest speech") {
            EmptyView()
        }
    }
}

/// Compact mode's one-line header: the live audio and the listening status.
private struct CompactStatusRow: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        let status = TranscriptStatus(session.status, modelProgress: session.speechModelProgress)
        HStack(spacing: 8) {
            Text("Transcript")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let caption = status.caption {
                Text(caption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
            LevelWaveform(read: { [session] in (them: session.themLevel, you: session.youLevel) }, isLive: status.isLive, barCount: 18)
                .frame(width: 64, height: 18)
        }
        .help(status.help)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// What the transcript column says about listening. No caption while all is well.
private struct TranscriptStatus {
    let caption: String?
    let color: Color
    let isLive: Bool
    let help: String

    /// `modelProgress`: the call language's speech model is downloading (0 to 1).
    init(_ status: MeetingSession.Status, modelProgress: Double? = nil) {
        switch status {
        case .starting:
            if let modelProgress {
                self.init(
                    caption: String(localized: "Speech model \(modelProgress.formatted(.percent.precision(.fractionLength(0))))", comment: "Overlay: the speech model's download progress, such as 42%."),
                    color: .orange,
                    isLive: false,
                    help: String(localized: "Downloading the speech model for this meeting's language. It's needed once per language.")
                )
            } else {
                self.init(caption: "Starting…", color: .orange, isLive: false, help: "Starting audio capture")
            }
        case .listening:
            self.init(caption: nil, color: .secondary, isLive: true, help: "Live audio. Above the line: the call. Below: your mic.")
        case .reconnecting:
            self.init(caption: "Reconnecting…", color: .orange, isLive: true, help: "The audio device changed; reconnecting")
        case .failed(let message):
            self.init(caption: "Paused", color: .red, isLive: false, help: message)
        case .ending:
            self.init(caption: "Ending…", color: .secondary, isLive: false, help: "Saving the meeting")
        case .ended:
            self.init(caption: "Ended", color: .secondary, isLive: false, help: "The meeting has ended")
        }
    }

    private init(caption: String?, color: Color, isLive: Bool, help: String) {
        self.caption = caption
        self.color = color
        self.isLive = isLive
        self.help = help
    }
}

// MARK: - Goal

/// The meeting goal; click to set or change it.
private struct GoalLine: View {
    @Environment(MeetingSession.self) private var session
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let goal = session.record.goal
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button {
            draft = goal
            editing = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(goal.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.violet))
                if goal.isEmpty {
                    Text("Set a goal for this meeting")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Goal")
                        .fontWeight(.semibold)
                        .foregroundStyle(Brand.violet)
                        .fixedSize()
                    Text(goal)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(goal.isEmpty ? Color.clear : Brand.violet.opacity(0.1), in: shape)
            .overlay {
                if goal.isEmpty {
                    shape.strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    shape.strokeBorder(Brand.violet.opacity(0.28))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Replies and Ask questions steer toward this goal. Click to change it.")
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
        VStack(spacing: 6) {
            ForEach(session.notices) { notice in
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice.message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = notice.settingsURL {
                        Button("Open Settings") { NSWorkspace.shared.open(url) }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button {
                        session.dismissNotice(notice.kind)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: shape)
                .overlay(shape.strokeBorder(Color.orange.opacity(0.3)))
            }
        }
    }
}
