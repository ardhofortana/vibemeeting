import AppKit
import SwiftUI

/// The dark glass look shared by the main window, New meeting, Add context and
/// the overlay: blurred desktop behind a deep navy tint, translucent fields
/// and cards, the brand gradient on the main action. These windows are always
/// dark (see `WindowManager`), so the translucent fills are light on dark.
enum Glass {
    static let fieldRadius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let fieldFill = Color.primary.opacity(0.06)
    static let fieldHoverFill = Color.primary.opacity(0.09)
    static let fieldStroke = Color.primary.opacity(0.1)
    static let focusStroke = Brand.accent.opacity(0.85)
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.09)
    static let divider = Color.primary.opacity(0.08)
    /// The deep navy laid over the blur.
    static let tint = Color(red: 0.035, green: 0.045, blue: 0.08)
}

// MARK: - Window

/// Where the system's title bar and window buttons sit in a glass window, so
/// a SwiftUI title row can line up with them. Set by `WindowManager`.
struct WindowChrome: Equatable {
    var titleBarHeight: CGFloat = 32
    /// Space to leave on the left for the close, minimize and zoom buttons.
    var leadingInset: CGFloat = 84
}

extension EnvironmentValues {
    @Entry var windowChrome = WindowChrome()
}

/// Blurred desktop behind the window with the navy tint on top. Glass windows
/// get it from `WindowManager`; views don't add it themselves.
struct GlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBlur()
            Glass.tint.opacity(0.55)
        }
        .ignoresSafeArea()
    }
}

/// Behind-window blur that stays on while the window is in the background.
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The row along the top of a glass window: room for the window buttons, the
/// app icon and a title, then anything trailing. Its height matches the
/// system title bar, so the buttons line up with it.
struct WindowTitleBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, chrome.leadingInset)
        .padding(.trailing, 14)
        .frame(height: max(chrome.titleBarHeight, 32))
    }
}

extension WindowTitleBar where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Logo

/// The logo's five bars in the brand gradient, without the app icon's tile.
struct LogoMark: View {
    var height: CGFloat = 24

    private static let bars: [CGFloat] = [0.32, 0.62, 1.0, 0.62, 0.32]

    var body: some View {
        let width = height * 0.16
        HStack(spacing: width * 0.85) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, scale in
                Capsule()
                    .frame(width: width, height: max(width, height * scale))
            }
        }
        .foregroundStyle(Brand.gradient(startPoint: .leading, endPoint: .trailing))
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Fields and cards

extension View {
    /// A translucent rounded field (text field, picker card); accent border while focused.
    func glassField(focused: Bool = false, radius: CGFloat = Glass.fieldRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Glass.fieldFill, in: shape)
            .overlay(shape.strokeBorder(focused ? Glass.focusStroke : Glass.fieldStroke, lineWidth: focused ? 1.5 : 1))
            .shadow(color: focused ? Brand.accent.opacity(0.35) : .clear, radius: 8)
    }

    /// A translucent rounded panel that groups related controls.
    func glassCard(radius: CGFloat = Glass.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Glass.cardFill, in: shape)
            .overlay(shape.strokeBorder(Glass.cardStroke))
    }
}

/// A section title with an icon, and an optional trailing accessory (a hint or a link).
struct GlassSectionHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension GlassSectionHeader where Trailing == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - Buttons

/// The main action of a window (Start listening, New meeting): the logo's
/// gradient with a white label and a soft glow.
struct PrimaryGradientButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, minHeight: minHeight)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(minHeight: minHeight)
                .background(shape.fill(Brand.gradient()))
                .overlay(shape.strokeBorder(Color.white.opacity(0.22)))
                .brightness(hovering && isEnabled ? 0.05 : 0)
                .shadow(color: Brand.violet.opacity(hovering && isEnabled ? 0.5 : 0.3), radius: 12, y: 3)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// A secondary action on glass (Cancel, menus next to the main action).
struct GlassButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, minHeight: minHeight)
    }

    private struct GlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minWidth: minHeight, minHeight: minHeight)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.1 : 0.06)))
                .overlay(shape.strokeBorder(Glass.fieldStroke))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// A round icon button on glass: New meeting in the main window's title row,
/// Star and Delete on a meeting.
struct GlassIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, diameter: diameter)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let diameter: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : 0.06)))
                .overlay(Circle().strokeBorder(Glass.fieldStroke))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Pale tints of the gradient with a dark label: Reply in the overlay,
/// Choose files in New meeting.
struct SoftGradientButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        SoftBody(configuration: configuration, minHeight: minHeight)
    }

    private struct SoftBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: minHeight)
                .background(shape.fill(Brand.softGradient()))
                .overlay(shape.strokeBorder(Color.white.opacity(0.4)))
                .brightness(hovering && isEnabled ? 0.03 : 0)
                .shadow(color: Brand.violet.opacity(hovering && isEnabled ? 0.4 : 0.22), radius: 10, y: 2)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// A warning on glass with a button that fixes it.
struct GlassNotice: View {
    let text: String
    let systemImage: String
    let action: String
    let perform: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action, action: perform)
                    .buttonStyle(GlassButtonStyle(minHeight: 28))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(Color.orange.opacity(0.3)))
    }
}
