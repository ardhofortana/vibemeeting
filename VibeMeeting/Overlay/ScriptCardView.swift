import AppKit
import SwiftUI
import VibeCore

/// The current script, for the compact (stacked) overlay. The split overlay
/// shows every response of the meeting instead (`ResponseListView`).
struct ScriptCardView: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        switch session.replyState {
        case .idle:
            EmptyView()
        case .failed(let failure):
            ResponseFailureRow(failure: failure)
                .responseCard(highlighted: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        case .drafting, .streaming, .done:
            if let script = session.currentScript {
                let card = ResponseCard(script: script, isLatest: true, showsHistory: true)
                    .responseCard(highlighted: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                // A long script scrolls rather than pushing the reply bar out.
                ViewThatFits(in: .vertical) {
                    card
                    ScrollView { card }
                }
            }
        }
    }
}

/// A failed Reply or Ask questions, with Try again when there is something to retry.
struct ResponseFailureRow: View {
    let failure: ReplyFailure
    @Environment(MeetingSession.self) private var session

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(failure.message).font(.system(size: 13))
            Spacer()
            if session.currentScript != nil, failure.canRetry {
                Button("Try again") { session.retry() }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// One script or set of questions. The first sentence of a script is bold so
/// the user can start talking while reading the rest. Only the latest response
/// gets Regenerate and Shorter, since those act on the latest one.
struct ResponseCard: View {
    let script: ReplyScript
    let isLatest: Bool
    var showsHistory = false
    @Environment(MeetingSession.self) private var session

    var body: some View {
        let isQuestions = script.intent == .questions
        let inFlight = isLatest && (session.replyState == .drafting || session.replyState == .streaming)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isQuestions ? "questionmark.bubble" : "arrowshape.turn.up.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isQuestions ? AnyShapeStyle(Brand.violet) : AnyShapeStyle(.secondary))
                Text(Self.header(for: script))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(isQuestions ? .tail : .head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tags
                Text(OverlayStyle.time(script.createdAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                if showsHistory { historyMenu }
            }

            if script.text.isEmpty && inFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isQuestions ? "Thinking of questions…" : "Drafting…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else if script.text.isEmpty {
                Text(isLatest ? "Nothing came back. Try Regenerate." : "Interrupted before any words came back.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if isQuestions {
                // A different set starts with nothing marked as copied.
                QuestionList(questions: ScriptText.questions(from: script.text, final: !inFlight))
                    .id(script.id)
            } else {
                Text(Self.styled(ScriptText.sanitize(script.text)))
                    .font(.system(size: 15))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if isLatest {
                    Button("Regenerate") { session.regenerate() }
                        .help(isQuestions
                            ? "Different questions (\(Hotkeys.label(.regenerate)))"
                            : "New script for the same target (\(Hotkeys.label(.regenerate)))")
                    if !isQuestions {
                        Button("Shorter") { session.shorter() }
                            .help("Shorten this script (\(Hotkeys.label(.shorter)))")
                            .disabled(script.text.isEmpty)
                    }
                }
                Button(isQuestions ? "Copy all" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.copyText(for: script), forType: .string)
                }
                .disabled(script.text.isEmpty)
                Spacer()
                if let latency = script.firstTokenLatency {
                    // Only when there's room next to the buttons.
                    ViewThatFits(in: .horizontal) {
                        Text(String(format: "%.1fs", latency))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .help("Time to first word")
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(isLatest && session.replyState == .drafting)
        }
    }

    @ViewBuilder
    private var tags: some View {
        if script.intent != .auto && script.intent != .questions {
            Text(script.intent.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Brand.sky)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Brand.accent.opacity(0.16), in: Capsule())
        }
        if script.variant != .fresh {
            Text(script.variant == .shorter ? "Shorter" : "Regenerated")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private var historyMenu: some View {
        Menu {
            let scripts = session.record.scripts.suffix(10).reversed()
            if scripts.isEmpty {
                Text("No earlier scripts")
            }
            ForEach(Array(scripts)) { script in
                Button {
                    session.showScript(script)
                } label: {
                    Text(String(Self.preview(of: script).prefix(70)))
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Earlier scripts in this meeting")
    }

    /// What the response answers, or what the questions aim at.
    static func header(for script: ReplyScript) -> String {
        guard script.intent == .questions else { return "“\(script.targetText)”" }
        return script.targetText.isEmpty ? "Questions to ask them" : "Questions toward: \(script.targetText)"
    }

    static func copyText(for script: ReplyScript) -> String {
        script.intent == .questions
            ? ScriptText.questions(from: script.text, final: true).joined(separator: "\n")
            : ScriptText.sanitize(script.text)
    }

    static func preview(of script: ReplyScript) -> String {
        script.intent == .questions
            ? "Questions: " + (ScriptText.questions(from: script.text, final: true).first ?? "")
            : ScriptText.sanitize(script.text)
    }

    /// First sentence in bold, [confirm number] markers highlighted.
    static func styled(_ text: String) -> AttributedString {
        let (first, rest) = ScriptText.splitFirstSentence(text)
        var result = highlighted(first, bold: true)
        if !rest.isEmpty {
            result += AttributedString(" ")
            result += highlighted(rest, bold: false)
        }
        return result
    }

    private static func highlighted(_ text: String, bold: Bool) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: ScriptText.confirmNumberMarker).enumerated() {
            if index > 0 {
                var marker = AttributedString(ScriptText.confirmNumberMarker)
                marker.foregroundColor = Color.orange
                marker.inlinePresentationIntent = .stronglyEmphasized
                result += marker
            }
            var run = AttributedString(part)
            if bold { run.inlinePresentationIntent = .stronglyEmphasized }
            result += run
        }
        return result
    }
}

extension View {
    /// The response card look: the latest one tinted with a gradient edge, older ones quieter.
    func responseCard(highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Brand.accent.opacity(0.1) : OverlayStyle.bubbleFill, in: shape)
            .overlay(shape.strokeBorder(
                highlighted
                    ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan.opacity(0.55), Brand.violet.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(OverlayStyle.bubbleStroke)
            ))
    }
}

/// Ask questions results: numbered, most useful first. Clicking one copies it.
struct QuestionList: View {
    let questions: [String]
    /// The question last copied (by text, so lines shifting while streaming don't move the mark).
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(question, forType: .string)
                    copied = question
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(question)
                            .font(.system(size: 15, weight: index == 0 ? .semibold : .regular))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if copied == question {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy this question")
            }
        }
    }
}
