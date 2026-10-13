import AppKit
import SwiftUI
import VibeCore

/// Live subtitles grouped by turn. Follows the conversation until the user
/// scrolls up, and again once they scroll back down or tap "Jump to live".
struct SubtitleListView: View {
    let compact: Bool
    @Environment(MeetingSession.self) private var session
    @State private var editingTurn: TranscriptTurn?

    var body: some View {
        let turns = session.transcript.turns
        let targetIDs = Set(session.pendingTarget?.turnIDs ?? [])

        Group {
            if turns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Waiting for someone to speak…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if compact {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(turns.suffix(2)) { turn in
                        row(turn, targetIDs: targetIDs)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            } else {
                fullList(turns, targetIDs: targetIDs)
            }
        }
        .popover(item: $editingTurn) { turn in
            TurnEditor(turn: turn) { text in
                session.editTurn(turn.id, text: text)
                editingTurn = nil
            }
        }
    }

    private func fullList(_ turns: [TranscriptTurn], targetIDs: Set<UUID>) -> some View {
        LiveScrollView(liveKey: Self.liveKey(turns), spacing: 16, contentPadding: 22) {
            ForEach(turns) { turn in
                row(turn, targetIDs: targetIDs)
            }
        }
    }

    private func row(_ turn: TranscriptTurn, targetIDs: Set<UUID>) -> some View {
        TurnRow(
            turn: turn,
            isTarget: targetIDs.contains(turn.id),
            isSelected: session.selectedTurnID == turn.id
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingTurn = turn }
        .onTapGesture { session.toggleTarget(turn.id) }
        .contextMenu {
            Button("Reply to this") {
                session.selectedTurnID = turn.id
                session.reply()
            }
            Button(session.selectedTurnID == turn.id ? "Clear target" : "Set as reply target") {
                session.toggleTarget(turn.id)
            }
            Button("Edit text…") { editingTurn = turn }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.text, forType: .string)
            }
        }
    }

    /// Changes whenever visible text grows anywhere near the end: a new turn, or
    /// more words in one of the last turns (Them and You can grow at once).
    static func liveKey(_ turns: [TranscriptTurn]) -> String {
        let tail = turns.suffix(3).map { "\($0.text.count)" }.joined(separator: ",")
        return "\(turns.count)-\(tail)"
    }
}

/// One turn: a dot, the speaker, the time, then the words. What they said sits
/// in a bubble; what you said is plain, dimmer text.
private struct TurnRow: View {
    let turn: TranscriptTurn
    /// The next Reply answers this turn.
    let isTarget: Bool
    /// The user picked this turn as the reply target.
    let isSelected: Bool

    private var isThem: Bool { turn.speaker == .them }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle()
                    .fill(isThem ? Brand.blue : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(turn.speaker.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isThem ? Brand.sky : Color.secondary)
                Text(OverlayStyle.time(turn.startedAt))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                if turn.editedText != nil {
                    Text("edited")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if isSelected {
                    Text("Reply target")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.sky)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Brand.accent.opacity(0.18), in: Capsule())
                }
            }
            if isThem {
                words
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bubbleShape.fill(isSelected ? Brand.accent.opacity(0.16) : OverlayStyle.bubbleFill))
                    .overlay(bubbleShape.strokeBorder(
                        isTarget ? Brand.accent.opacity(0.6) : OverlayStyle.bubbleStroke,
                        lineWidth: isTarget ? 1.2 : 1
                    ))
                    .padding(.leading, 12)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Capsule()
                        .fill(isTarget ? Brand.accent : Color.clear)
                        .frame(width: 2.5)
                        .padding(.leading, 12)
                        .padding(.trailing, 9.5)
                    words
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    isSelected ? Brand.accent.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private var words: some View {
        text
            .font(.system(size: 14))
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: Text {
        if let edited = turn.editedText {
            return Text(edited)
        }
        var text = AttributedString(turn.finalText)
        if !turn.volatileText.isEmpty {
            // Text that may still change is shown dimmer.
            var live = AttributedString((turn.finalText.isEmpty ? "" : " ") + turn.volatileText)
            live.foregroundColor = isThem ? Color.secondary : OverlayStyle.faintText
            text += live
        }
        return Text(text)
    }
}

/// Quick fix for misheard words before replying.
private struct TurnEditor: View {
    let turn: TranscriptTurn
    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(turn: TranscriptTurn, onSave: @escaping (String) -> Void) {
        self.turn = turn
        self.onSave = onSave
        _text = State(initialValue: turn.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix what \(turn.speaker.label) said")
                .font(.headline)
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSave(text) }
            HStack {
                Spacer()
                Button("Save") { onSave(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}
