import AppKit
import SwiftUI
import VibeCore

/// Live subtitles grouped by turn. Follows the conversation until the user
/// scrolls up, and again once they scroll back down or tap "Jump to live".
struct SubtitleListView: View {
    let compact: Bool
    @Environment(MeetingSession.self) private var session
    @State private var pinnedToBottom = true
    @State private var editingTurn: TranscriptTurn?

    var body: some View {
        let turns = session.transcript.turns
        let targetIDs = Set(session.pendingTarget?.turnIDs ?? [])

        Group {
            if turns.isEmpty {
                Text("Waiting for someone to speak…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if compact {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turns.suffix(2)) { turn in
                        row(turn, targetIDs: targetIDs)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 12)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(turns) { turn in
                        row(turn, targetIDs: targetIDs)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            // While following, growing text keeps the bottom in view as it lays out.
            .defaultScrollAnchor(pinnedToBottom ? UnitPoint.bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(
                    offset: geometry.contentOffset.y,
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                )
            } action: { old, new in
                // New text makes the content taller, which also leaves the bottom for a
                // moment; that must not stop following. Only the user moving up does.
                if new.atBottom {
                    pinnedToBottom = true
                } else if new.offset < old.offset - 1 {
                    pinnedToBottom = false
                }
            }
            .onChange(of: Self.liveKey(turns)) {
                guard pinnedToBottom else { return }
                // After this update is laid out, so the new line is measured.
                Task { @MainActor in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Jump to live", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 6)
                }
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

    static let bottomID = "live-bottom"

    /// Changes whenever visible text grows anywhere near the end: a new turn, or
    /// more words in one of the last turns (Them and You can grow at once).
    static func liveKey(_ turns: [TranscriptTurn]) -> String {
        let tail = turns.suffix(3).map { "\($0.text.count)" }.joined(separator: ",")
        return "\(turns.count)-\(tail)"
    }

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var atBottom: Bool
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn
    let isTarget: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isTarget ? Color.accentColor : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(turn.speaker.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(turn.speaker == .them ? Color.accentColor : Color.secondary)
                    if turn.editedText != nil {
                        Text("edited")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if isSelected {
                        Text("target")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                text
                    .font(turn.speaker == .them ? .body : .callout)
                    .foregroundStyle(turn.speaker == .them ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(turn.speaker == .you ? 0.75 : 1)
    }

    private var text: Text {
        if let edited = turn.editedText {
            return Text(edited)
        }
        var text = AttributedString(turn.finalText)
        if !turn.volatileText.isEmpty {
            // Text that may still change is shown dimmer.
            var live = AttributedString((turn.finalText.isEmpty ? "" : " ") + turn.volatileText)
            live.foregroundColor = Color.secondary
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
