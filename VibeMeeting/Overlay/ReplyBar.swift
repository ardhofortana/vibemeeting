import KeyboardShortcuts
import SwiftUI
import VibeCore

/// The bottom card: intent chips and Ask questions, the Steer field with the
/// main Reply button, and the hotkey hints. A chip replies right away with its
/// intent and lights up while that response is being written.
struct ReplyBar: View {
    let controller: OverlayController
    @Environment(MeetingSession.self) private var session
    @Environment(\.overlayDensity) private var density
    @FocusState private var steerFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            // The widest row that fits: icons and labels, then labels only (tighter
            // the second time), then icons only.
            ViewThatFits(in: .horizontal) {
                chips(icons: true, labels: true)
                chips(icons: false, labels: true)
                chips(icons: false, labels: true, tight: true)
                chips(icons: true, labels: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                steerField
                replyButton
            }

            HotkeyHints()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .overlayCard()
        .onChange(of: session.steerFocusRequest) {
            steerFocused = true
        }
    }

    private var isWorking: Bool {
        session.replyState == .drafting || session.replyState == .streaming
    }

    /// The chip for the response being written right now.
    private func isActive(_ intent: ReplyIntent) -> Bool {
        isWorking && session.currentScript?.intent == intent
    }

    private func chips(icons: Bool, labels: Bool, tight: Bool = false) -> some View {
        HStack(spacing: tight ? 6 : 10) {
            ForEach(ReplyIntent.explicit) { intent in
                Button {
                    session.reply(intent: intent)
                    controller.releaseFocus()
                } label: {
                    chipLabel(
                        intent.label,
                        systemImage: Self.icon(for: intent, active: isActive(intent)),
                        iconStyle: isActive(intent) ? AnyShapeStyle(Brand.gradient(startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(.primary),
                        icons: icons,
                        labels: labels
                    )
                }
                .buttonStyle(ChipButtonStyle(active: isActive(intent), horizontalPadding: tight ? 9 : 15))
                .help("\(Self.help(for: intent)) (\(Hotkeys.label(Self.hotkey(for: intent))))")
            }
            Button {
                session.askQuestions()
                controller.releaseFocus()
            } label: {
                chipLabel(
                    tight ? "Questions" : "Ask questions",
                    systemImage: "questionmark.bubble",
                    iconStyle: AnyShapeStyle(LinearGradient(colors: [Brand.violet, Brand.blue], startPoint: .topLeading, endPoint: .bottomTrailing)),
                    icons: icons,
                    labels: labels
                )
                .accessibilityLabel("Ask questions")
            }
            .buttonStyle(ChipButtonStyle(active: isActive(.questions), horizontalPadding: tight ? 9 : 15))
            .help("Questions to ask them so the meeting gets clearer, toward your goal (\(Hotkeys.label(.askQuestions))). The steer text focuses them.")
            .disabled(session.replyState == .drafting)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func chipLabel(_ title: String, systemImage: String, iconStyle: AnyShapeStyle, icons: Bool, labels: Bool) -> some View {
        HStack(spacing: 9) {
            if icons {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(iconStyle)
            }
            if labels {
                Text(title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var steerField: some View {
        @Bindable var session = session
        let shape = RoundedRectangle(cornerRadius: OverlayStyle.controlRadius, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.gradient(startPoint: .topLeading, endPoint: .bottomTrailing))
            TextField("Steer the reply (optional), e.g. agree, but ask for a week", text: $session.steerText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($steerFocused)
                .onSubmit(submitSteer)
                .onExitCommand {
                    steerFocused = false
                    controller.releaseFocus()
                }
            Button(action: submitSteer) {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reply with this steer (Return)")
            .disabled(session.replyState == .drafting)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 46)
        .background(OverlayStyle.controlFill, in: shape)
        .overlay(shape.strokeBorder(
            steerFocused ? Brand.accent.opacity(0.75) : OverlayStyle.controlStroke,
            lineWidth: steerFocused ? 1.5 : 1
        ))
        // A click anywhere in the box, not just on the text line, starts typing.
        .contentShape(shape)
        .onTapGesture {
            controller.makeKeyForTyping()
            steerFocused = true
        }
        .help("Optional: how the next reply should go. Focus it with \(Hotkeys.label(.steer)).")
    }

    private var replyButton: some View {
        Button {
            session.reply()
            controller.releaseFocus()
        } label: {
            HStack(spacing: 12) {
                Text(density == .narrow ? "Reply" : "Reply \(Hotkeys.label(.reply))")
                Image(systemName: "paperplane")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(45))
            }
        }
        .buttonStyle(ReplyButtonStyle())
        .fixedSize()
        .help("Reply to what they just said; Claude picks the best move (\(Hotkeys.label(.reply)))")
        .disabled(session.replyState == .drafting)
    }

    private func submitSteer() {
        session.reply()
        steerFocused = false
        controller.releaseFocus()
    }

    static func icon(for intent: ReplyIntent, active: Bool) -> String {
        switch intent {
        case .answer: return active ? "ellipsis.bubble.fill" : "ellipsis.bubble"
        case .clarify: return "questionmark"
        case .add: return "plus"
        case .pushBack: return active ? "shield.fill" : "shield"
        case .auto, .questions: return "questionmark.bubble"
        }
    }

    static func help(for intent: ReplyIntent) -> String {
        switch intent {
        case .answer: return "Answer the question"
        case .clarify: return "Correct politely or ask back"
        case .add: return "Add a point"
        case .pushBack: return "Disagree politely"
        case .auto, .questions: return intent.label
        }
    }

    static func hotkey(for intent: ReplyIntent) -> KeyboardShortcuts.Name {
        switch intent {
        case .answer: return .answer
        case .clarify: return .clarify
        case .add: return .add
        case .pushBack: return .pushBack
        case .auto: return .reply
        case .questions: return .askQuestions
        }
    }
}

/// Hotkeys along the bottom of the overlay; drops the less used ones when narrow.
private struct HotkeyHints: View {
    /// A hotkey and its localized label, kept apart so word order never matters.
    private typealias Hint = (key: String, label: LocalizedStringResource)

    var body: some View {
        let reply: Hint = (key: Hotkeys.label(.reply), label: "Reply")
        let questions: Hint = (key: Hotkeys.label(.askQuestions), label: "Ask questions")
        let intents: Hint = (key: Hotkeys.rangeLabel(.answer, .pushBack), label: "Intents")
        let steer: Hint = (key: Hotkeys.label(.steer), label: "Steer")
        let regenerate: Hint = (key: Hotkeys.label(.regenerate), label: "Regenerate")
        let shorter: Hint = (key: Hotkeys.label(.shorter), label: "Shorter")
        let hide: Hint = (key: Hotkeys.label(.toggleOverlay), label: "Hide")
        ViewThatFits(in: .horizontal) {
            Self.line([reply, questions, intents, steer, regenerate, shorter, hide])
            Self.line([reply, questions, intents, regenerate, shorter, hide])
            Self.line([reply, questions, regenerate, shorter, hide])
            Self.line([reply, questions, hide])
        }
        .frame(maxWidth: .infinity)
    }

    private static func line(_ items: [Hint]) -> some View {
        var text = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                var separator = AttributedString("    |    ")
                separator.foregroundColor = Color.primary.opacity(0.18)
                text += separator
            }
            var key = AttributedString(item.key)
            key.foregroundColor = Color.primary.opacity(0.85)
            text += key
            text += AttributedString("  ")
            var label = AttributedString(String(localized: item.label))
            label.foregroundColor = Color.secondary
            text += label
        }
        return Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
    }
}
