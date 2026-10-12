import SwiftUI

/// A scroll view that follows new content at the bottom, like a chat: it keeps
/// following until the user scrolls up, and again once they scroll back down or
/// tap "Jump to latest". Used for the subtitles and the response list.
struct LiveScrollView<Content: View>: View {
    /// Changes whenever content near the bottom grows (a new item, more text).
    let liveKey: String
    var jumpLabel = "Jump to live"
    @ViewBuilder let content: () -> Content
    @State private var pinnedToBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    content()
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
            .onChange(of: liveKey) {
                guard pinnedToBottom else { return }
                // After this update is laid out, so the new content is measured.
                Task { @MainActor in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label(jumpLabel, systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private static var bottomID: String { "live-bottom" }

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var atBottom: Bool
    }
}
