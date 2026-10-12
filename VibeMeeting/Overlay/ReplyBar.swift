import SwiftUI
import VibeCore

/// Intent chips, the Steer field, and the main Reply button.
struct ReplyBar: View {
    let controller: OverlayController
    @Environment(MeetingSession.self) private var session
    @FocusState private var steerFocused: Bool

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ReplyIntent.explicit) { intent in
                    Button(intent.label) {
                        session.reply(intent: intent)
                        controller.releaseFocus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                TextField("Steer the reply (optional), e.g. offer 2 revisions", text: $session.steerText)
                    .textFieldStyle(.roundedBorder)
                    .focused($steerFocused)
                    .onSubmit {
                        session.reply()
                        steerFocused = false
                        controller.releaseFocus()
                    }
                    .onExitCommand {
                        steerFocused = false
                        controller.releaseFocus()
                    }

                Button {
                    session.reply()
                    controller.releaseFocus()
                } label: {
                    Text("Reply \(Hotkeys.label(.reply))")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.replyState == .drafting)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onChange(of: session.steerFocusRequest) {
            steerFocused = true
        }
    }
}
