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
                VStack(spacing: 6) {
                    Text("No responses yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Press Reply (\(Hotkeys.label(.reply))) or Ask questions (\(Hotkeys.label(.askQuestions))). Every response stays here for the whole meeting.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveScrollView(
                    liveKey: Self.liveKey(responses, state: session.replyState),
                    jumpLabel: "Jump to latest",
                    // A new Reply, Ask questions, Regenerate or Shorter: show it.
                    followKey: session.currentScript?.id.uuidString ?? ""
                ) {
                    ForEach(responses) { script in
                        ResponseCard(script: script, isLatest: script.id == latestID)
                            .responseCard(highlighted: script.id == latestID)
                    }
                    if case .failed(let message) = session.replyState {
                        ResponseFailureRow(message: message)
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
