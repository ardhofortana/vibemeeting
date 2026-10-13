import SwiftUI

/// The meeting overlay's look: dark glass, soft cards, chips and the gradient
/// Reply button. The overlay is always dark (see `OverlayController`), so the
/// translucent fills below are light on dark.
enum OverlayStyle {
    static let windowRadius: CGFloat = 18
    static let cardRadius: CGFloat = 15
    static let controlRadius: CGFloat = 10

    /// Cards sit a little darker than the glass, as if recessed.
    static let cardFill = Color.black.opacity(0.15)
    static let cardStroke = Color.primary.opacity(0.13)
    static let bubbleFill = Color.primary.opacity(0.07)
    static let bubbleStroke = Color.primary.opacity(0.07)
    static let controlFill = Color.primary.opacity(0.06)
    static let controlHoverFill = Color.primary.opacity(0.1)
    static let controlStroke = Color.primary.opacity(0.1)
    static let divider = Color.primary.opacity(0.15)
    /// Like `.tertiary`, for text built from attributed runs.
    static let faintText = Color.primary.opacity(0.42)

    /// Time of a turn or a response, e.g. "10:22".
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// How much room the overlay has; narrower overlays drop labels first.
enum OverlayDensity: Comparable {
    case narrow
    case medium
    case regular

    init(width: CGFloat) {
        if width >= 760 {
            self = .regular
        } else if width >= 540 {
            self = .medium
        } else {
            self = .narrow
        }
    }
}

extension EnvironmentValues {
    @Entry var overlayDensity: OverlayDensity = .regular
}

extension View {
    /// A rounded area inside the overlay: the transcript and responses, the reply bar.
    func overlayCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: OverlayStyle.cardRadius, style: .continuous)
        return background(OverlayStyle.cardFill, in: shape)
            .overlay(shape.strokeBorder(OverlayStyle.cardStroke))
    }
}

// MARK: - Buttons

/// Icon-only header button with a soft circle on hover.
struct OverlayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0)))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// An intent chip (Answer, Clarify, Add, Push back, Ask questions). `active`
/// while that response is being written.
struct ChipButtonStyle: ButtonStyle {
    var active = false
    var horizontalPadding: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, active: active, horizontalPadding: horizontalPadding)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let horizontalPadding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: 36, minHeight: 36)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(stroke, lineWidth: active ? 1.3 : 1))
                .shadow(color: active ? Brand.blue.opacity(0.25) : .clear, radius: 3)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                // A chip whose response is being written stays lit even while disabled.
                .opacity(isEnabled || active ? 1 : 0.45)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if active { return Brand.blue.opacity(0.08) }
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            return hovering ? OverlayStyle.controlHoverFill : OverlayStyle.controlFill
        }

        private var stroke: AnyShapeStyle {
            active
                ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan, Brand.blue, Brand.violet], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(OverlayStyle.controlStroke)
        }
    }
}

/// The main Reply button: the logo's gradient in pale tints, dark label.
struct ReplyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftGradientButtonStyle(minHeight: 46).makeBody(configuration: configuration)
    }
}

/// End meeting: solid red.
struct EndMeetingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: 32, minHeight: 30)
            .background(shape.fill(Color(red: 0.87, green: 0.22, blue: 0.25).opacity(configuration.isPressed ? 0.8 : 1)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.14)))
            .contentShape(shape)
    }
}

/// Small actions on a response card (Regenerate, Shorter, Copy, Try again).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.12 : 0.07)))
                .overlay(Capsule().strokeBorder(OverlayStyle.controlStroke))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Window controls

/// The overlay's own close, minimize and zoom lights. The panel never takes
/// focus from the meeting app, so the system's lights would stay gray; these
/// keep their color. Close and minimize hide the overlay (the meeting keeps
/// running; bring it back with the hotkey or the menu bar), zoom switches
/// between the split and compact layouts.
struct OverlayWindowControls: View {
    let isCompact: Bool
    let onHide: () -> Void
    let onZoom: () -> Void
    @State private var hovering = false

    var body: some View {
        let hideHelp = "Hide the overlay (\(Hotkeys.label(.toggleOverlay))). The meeting keeps running."
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.373, blue: 0.341), glyph: "xmark", help: hideHelp, label: "Hide overlay", action: onHide)
            light(Color(red: 0.996, green: 0.737, blue: 0.180), glyph: "minus", help: hideHelp, label: "Hide overlay", action: onHide)
            light(
                Color(red: 0.157, green: 0.784, blue: 0.251),
                glyph: isCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                help: isCompact ? "Transcript and responses side by side" : "Compact mode",
                label: isCompact ? "Side by side layout" : "Compact mode",
                action: onZoom
            )
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, glyph: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                .overlay {
                    if hovering {
                        Image(systemName: glyph)
                            .font(.system(size: 6.5, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}
