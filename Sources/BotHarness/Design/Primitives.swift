import SwiftUI

/// The component layer. Everything the interface is built from, with every state it can be in.
///
/// The reason each of these exists as a type rather than as a pile of modifiers repeated at
/// each call site: a state that is only implemented where someone remembered it is a state
/// that is wrong somewhere. Hover, press, disabled, loading and empty are defined once, here,
/// and every use gets all five.

// MARK: - Buttons

/// Press feedback for anything pressable.
///
/// Subtle scale plus a slight dim. The point is not decoration — it is that the interface is
/// visibly listening. Without it a click feels like it may not have registered, and people
/// click again.
public struct PressableStyle: ButtonStyle {
    public var scale: CGFloat = DS.Motion.pressScale
    public init(scale: CGFloat = DS.Motion.pressScale) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

/// A square icon button. The most common control in the app.
public struct IconButton: View {
    let systemName: String
    var size: CGFloat = DS.Size.iconButton
    var glyph: CGFloat = DS.Size.glyph
    var filled = true
    var tint: Color = DS.Ink.secondary
    var help: String?
    var isLoading = false
    let action: () -> Void

    @State private var hovering = false

    public init(_ systemName: String, size: CGFloat = DS.Size.iconButton,
                glyph: CGFloat = DS.Size.glyph, filled: Bool = true,
                tint: Color = DS.Ink.secondary, help: String? = nil,
                isLoading: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName; self.size = size; self.glyph = glyph
        self.filled = filled; self.tint = tint; self.help = help
        self.isLoading = isLoading; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if filled {
                    Circle().fill(hovering ? DS.Tint.t4 : DS.Tint.t3)
                }
                if isLoading {
                    Spinner(size: glyph)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: glyph, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isLoading)
        .onHover { hovering = $0 }
        .dsAnimation(DS.Motion.instant, value: hovering)
        .help(help ?? "")
    }
}

/// The one button on screen that is the obvious thing to do.
public struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, isLoading: Bool = false,
                isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage
        self.isLoading = isLoading; self.isEnabled = isEnabled; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                if isLoading {
                    Spinner(size: 10, tint: Color.white)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: DS.Size.glyphSmall, weight: .semibold))
                }
                Text(isLoading ? "Working" : title).font(DS.Text.caption.weight(.medium))
            }
            .foregroundStyle(isEnabled ? Color.white : DS.Ink.quaternary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md - 1)
            .background(isEnabled ? DS.Accent.live : DS.Tint.t3,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))
            // Content changes size when it swaps to a spinner; blur bridges the two states so
            // the eye reads one control changing rather than two controls swapping.
            .animation(DS.Motion.instant, value: isLoading)
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled || isLoading)
    }
}

/// Everything that is not the primary action.
public struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    let action: () -> Void

    @State private var hovering = false

    public init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil,
                action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: DS.Size.glyphSmall))
                }
                Text(title).font(DS.Text.caption)
            }
            .foregroundStyle(role == .destructive ? DS.Status.failed.mark : DS.Ink.primary)
            .padding(.horizontal, DS.Space.lg - 1)
            .padding(.vertical, DS.Space.sm)
            .background(hovering ? DS.Tint.t4 : DS.Tint.t3,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .dsAnimation(DS.Motion.instant, value: hovering)
    }
}

// MARK: - Surfaces

/// A card. One radius, one fill, one optional hairline.
public struct Surface<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    var radius: CGFloat = DS.Radius.lg
    var fill: Color = DS.Surface.raised
    var bordered = true
    var borderTint: Color = DS.Tint.t6
    @ViewBuilder let content: Content

    public init(padding: CGFloat = DS.Space.lg, radius: CGFloat = DS.Radius.lg,
                fill: Color = DS.Surface.raised, bordered: Bool = true,
                borderTint: Color = DS.Tint.t6, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.radius = radius; self.fill = fill
        self.bordered = bordered; self.borderTint = borderTint; self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(bordered ? borderTint : .clear, lineWidth: DS.Size.hairline)
            )
    }
}

/// A small label with a value. Used for model, autonomy, status.
public struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = DS.Ink.secondary
    var showsChevron = false

    public init(_ text: String, systemImage: String? = nil,
                tint: Color = DS.Ink.secondary, showsChevron: Bool = false) {
        self.text = text; self.systemImage = systemImage
        self.tint = tint; self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9)).foregroundStyle(tint)
            }
            Text(text).font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DS.Ink.tertiary)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Tint.t3, in: Capsule())
        .contentShape(Capsule())
    }
}

/// A coloured dot plus a word. The app's only status vocabulary.
public struct StatusPill: View {
    public enum State: Sendable {
        case running, done, failed, waiting, idle

        var tint: Color {
            switch self {
            case .running: return DS.Status.running.mark
            case .done:    return DS.Status.done.mark
            case .failed:  return DS.Status.failed.mark
            case .waiting: return DS.Status.waiting.mark
            case .idle:    return DS.Ink.tertiary
            }
        }
    }

    let state: State
    let label: String
    public init(_ state: State, _ label: String) { self.state = state; self.label = label }

    public var body: some View {
        HStack(spacing: DS.Space.xs + 1) {
            Circle().fill(state.tint).frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            Text(label).font(DS.Text.micro.weight(.medium)).foregroundStyle(DS.Ink.secondary)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.hair + 1)
        .background(DS.Tint.t3, in: Capsule())
    }
}

// MARK: - Loading

/// A spinner sized to sit inside a control.
///
/// Deliberately faster than the system default: a quicker spin makes an identical wait feel
/// shorter, and this one appears inside buttons where the wait is usually brief anyway.
public struct Spinner: View {
    var size: CGFloat = 12
    var tint: Color = DS.Ink.secondary
    @State private var spinning = false

    public init(size: CGFloat = 12, tint: Color = DS.Ink.secondary) {
        self.size = size; self.tint = tint
    }

    public var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(tint, style: StrokeStyle(lineWidth: max(1.2, size / 9), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.72).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// A placeholder for content that is on its way.
///
/// Shaped like the thing it replaces, so the layout does not jump when the real content
/// arrives. The shimmer is slow and low-contrast — a placeholder that draws attention to
/// itself is worse than a blank space.
public struct Skeleton: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = DS.Radius.xs
    @State private var phase: CGFloat = -1

    public init(width: CGFloat? = nil, height: CGFloat = 12, radius: CGFloat = DS.Radius.xs) {
        self.width = width; self.height = height; self.radius = radius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(DS.Tint.t3)
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

/// Several skeleton lines, for a paragraph or a list that is loading.
public struct SkeletonBlock: View {
    var lines: Int = 3
    public init(lines: Int = 3) { self.lines = lines }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(0..<lines, id: \.self) { index in
                // Ragged right edge, like real prose. A stack of equal bars reads as a table.
                Skeleton(width: index == lines - 1 ? 140 : nil, height: 11)
            }
        }
    }
}

// MARK: - Empty and error states

/// What a surface says when it has nothing to show.
///
/// Every one of these has a title, a sentence explaining what will put something here, and —
/// where there is one — the action that would. An empty state without a next step is a dead
/// end that happens to be polite.
public struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    public init(systemImage: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DS.Ink.tertiary)
            VStack(spacing: DS.Space.xs + 1) {
                Text(title).font(DS.Text.title).foregroundStyle(DS.Ink.primary)
                Text(message)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                SecondaryButton(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxxl)
    }
}

/// What a surface says when something went wrong. Same shape as empty, different tone, and
/// always with a way to try again.
public struct ErrorState: View {
    let message: String
    var retry: (() -> Void)?

    public init(_ message: String, retry: (() -> Void)? = nil) {
        self.message = message; self.retry = retry
    }

    public var body: some View {
        Surface(fill: DS.Status.failed.mark.opacity(0.09), borderTint: DS.Status.failed.mark.opacity(0.25)) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DS.Size.glyphSmall))
                    .foregroundStyle(DS.Status.failed.mark)
                Text(message)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.md)
                if let retry { SecondaryButton("Try again", action: retry) }
            }
        }
    }
}

// MARK: - Structure

/// A small uppercase label above a group.
public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(DS.Ink.tertiary)
    }
}

/// The app's only divider.
public struct Hairline: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(DS.Tint.t6).frame(height: DS.Size.hairline)
    }
}

/// A row that reveals more when tapped. Used for tool cards and the activity stream.
public struct Disclosure<Header: View, Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    public init(expanded: Binding<Bool>, @ViewBuilder header: () -> Header,
                @ViewBuilder content: () -> Content) {
        self._expanded = expanded; self.header = header(); self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Ink.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    header
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { content }
        }
        .dsAnimation(DS.Motion.panel, value: expanded)
    }
}


// MARK: - Inset helper

public extension View {
    /// Apply a named component inset.
    func dsInset(_ insets: EdgeInsets) -> some View { padding(insets) }
}

// MARK: - Reading column

/// Centres content and stops it widening past a comfortable measure.
///
/// The single most effective thing a chat layout can do on a large display. Without it, prose
/// stretches to whatever width the window happens to be, which is the clearest sign a layout
/// was only ever looked at in one window size.
public struct ReadingColumn<Content: View>: View {
    var maxWidth: CGFloat = DS.Size.readingMax
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder let content: Content

    public init(maxWidth: CGFloat = DS.Size.readingMax,
                alignment: HorizontalAlignment = .leading,
                @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth; self.alignment = alignment; self.content = content()
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 0) { content }
            // Two frames, not a Spacer. The inner one caps the measure; the outer one claims
            // the available width and anchors the capped column to its leading edge.
            //
            // The Spacer version overflowed: in an HStack the column asks for its full
            // maxWidth, and when the pane is narrower than that the stack hands it the width
            // it asked for and the transcript runs off the right edge of the window.
            .frame(maxWidth: maxWidth, alignment: Alignment(horizontal: alignment, vertical: .center))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DS.Space.xxl)
            .padding(.trailing, DS.Space.lg)
    }
}

