import SwiftUI
import VibeCore

/// Every reply and Ask questions result of this meeting, oldest first, so the
/// latest is at the bottom next to the Reply bar. Scrollable; follows new
/// responses until the user scrolls up.
struct ResponseListView: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        let inFlight = session.replyState == .drafting || session.replyState == .streaming
        let responses = Self.responses(saved: session.record.scripts, current: session.currentScript, inFlight: inFlight)
        let latestID = session.currentScript?.id ?? responses.last?.id

        Group {
            if responses.isEmpty && !Self.isFailure(session.replyState) {
                ResponsesEmptyState()
            } else {
                LiveScrollView(
                    liveKey: Self.liveKey(responses, state: session.replyState),
                    jumpLabel: "Jump to latest",
                    // A new Reply, Ask questions, Regenerate or Shorter: show it.
                    followKey: session.currentScript?.id.uuidString ?? "",
                    spacing: 12,
                    contentPadding: 22
                ) {
                    ForEach(responses) { script in
                        ResponseCard(script: script, isLatest: script.id == latestID)
                            .responseCard(highlighted: script.id == latestID)
                    }
                    if case .failed(let failure) = session.replyState {
                        ResponseFailureRow(failure: failure)
                            .responseCard(highlighted: true)
                    }
                }
            }
        }
    }

    /// Saved responses plus the one still streaming (it's saved when it finishes).
    /// A failed request isn't saved, so it shows only as the failure row.
    static func responses(saved: [ReplyScript], current: ReplyScript?, inFlight: Bool) -> [ReplyScript] {
        guard inFlight, let current, !saved.contains(where: { $0.id == current.id }) else { return saved }
        return saved + [current]
    }

    static func liveKey(_ responses: [ReplyScript], state: MeetingSession.ReplyState) -> String {
        "\(responses.count)-\(responses.last?.text.count ?? 0)-\(isFailure(state))"
    }

    static func isFailure(_ state: MeetingSession.ReplyState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// Before the first Reply or Ask questions. Drops the symbol when the column is short.
private struct ResponsesEmptyState: View {
    var body: some View {
        ViewThatFits(in: .vertical) {
            content(withSymbol: true)
            content(withSymbol: false)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
    }

    private func content(withSymbol: Bool) -> some View {
        VStack(spacing: 10) {
            if withSymbol {
                ZStack {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 46, weight: .light))
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .regular))
                        .offset(y: -3)
                }
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.bottom, 8)
            }
            Text("No responses yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Press Reply (\(Hotkeys.label(.reply))) or ask questions (\(Hotkeys.label(.askQuestions))).\nEvery response stays here for the whole meeting.")
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
