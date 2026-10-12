import AppKit
import SwiftUI
import VibeCore

/// The script to read out loud. The first sentence is bold so the user can
/// start talking while reading the rest. Ask questions results show as a list.
struct ScriptCardView: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        switch session.replyState {
        case .idle:
            EmptyView()
        case .failed(let message):
            card {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(message).font(.callout)
                    Spacer()
                    if session.currentScript != nil, message != "Nothing to reply to yet." {
                        Button("Try again") { session.retry() }
                            .controlSize(.small)
                    }
                }
            }
        case .drafting, .streaming, .done:
            if let script = session.currentScript {
                card { content(for: script) }
            }
        }
    }

    @ViewBuilder
    private func content(for script: ReplyScript) -> some View {
        let isQuestions = script.intent == .questions
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isQuestions {
                    Image(systemName: "questionmark.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(script.targetText.isEmpty ? "Questions to ask them" : "Questions toward: \(script.targetText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("“\(script.targetText)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                tags(for: script)
                historyMenu
            }

            if script.text.isEmpty && session.replyState != .done {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isQuestions ? "Thinking of questions…" : "Drafting…").foregroundStyle(.secondary)
                }
            } else if script.text.isEmpty {
                Text("Nothing came back. Try Regenerate.").foregroundStyle(.secondary)
            } else if isQuestions {
                // A different set starts with nothing marked as copied.
                QuestionList(questions: ScriptText.questions(from: script.text, final: session.replyState == .done))
                    .id(script.id)
            } else {
                Text(Self.styled(ScriptText.sanitize(script.text)))
                    .font(.title3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Regenerate") { session.regenerate() }
                    .help(isQuestions
                        ? "Different questions (\(Hotkeys.label(.regenerate)))"
                        : "New script for the same target (\(Hotkeys.label(.regenerate)))")
                if !isQuestions {
                    Button("Shorter") { session.shorter() }
                        .help("Shorten this script (\(Hotkeys.label(.shorter)))")
                        .disabled(script.text.isEmpty)
                }
                Button(isQuestions ? "Copy all" : "Copy") {
                    let text = isQuestions
                        ? ScriptText.questions(from: script.text, final: true).joined(separator: "\n")
                        : ScriptText.sanitize(script.text)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(script.text.isEmpty)
                Spacer()
                if let latency = script.firstTokenLatency {
                    Text(String(format: "%.1fs", latency))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("Time to first word")
                }
            }
            .controlSize(.small)
            .disabled(session.replyState == .drafting)
        }
    }

    @ViewBuilder
    private func tags(for script: ReplyScript) -> some View {
        if script.intent != .auto && script.intent != .questions {
            Text(script.intent.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        if script.variant != .fresh {
            Text(script.variant == .shorter ? "Shorter" : "Regenerated").font(.caption2).foregroundStyle(.tertiary)
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
                    let preview = script.intent == .questions
                        ? "Questions: " + (ScriptText.questions(from: script.text, final: true).first ?? "")
                        : ScriptText.sanitize(script.text)
                    Text(String(preview.prefix(70)))
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

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
            .padding(.horizontal, 10)
            .padding(.top, 6)
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

/// Ask questions results: numbered, most useful first. Clicking one copies it.
private struct QuestionList: View {
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
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(question)
                            .font(index == 0 ? .title3.weight(.semibold) : .title3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
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
