import SwiftUI

/// The interaction layer: hover, press and reduced motion, implemented once.
///
/// These were specified in the token file and never applied, which is most of why the app felt
/// unfinished. A list whose rows do not respond to the cursor reads as a picture of a list.

// MARK: - Hover

/// Hover with the asymmetry the motion spec calls for.
///
/// **In is instant; only out animates.** A cursor crossing a roster should not trail glow
/// behind it — animating the entry means every row the pointer passes lights up late and fades
/// late, which is the strobing that makes a list feel cheap.
///
/// **Rows wait `hoverRowDelay` before showing hover at all**, so traversing the list does not
/// flash every row on the way past. Buttons pass `delay: 0`, because a button under the cursor
/// is a destination rather than something passed through.
public struct HoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var shape: AnyShape
    var resting: Color
    var hovered: Color
    var delay: Double

    @State private var isHovering = false
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    public func body(content: Content) -> some View {
        content
            .background(shape.fill(isShown ? hovered : resting))
            // Only the exit is animated. Entry sets the value directly.
            .animation(isShown ? nil : DS.Motion.gated(DS.Motion.hoverOut,
                                                       reduceMotion: reduceMotion,
                                                       opacityOnly: true),
                       value: isShown)
            .onHover { hovering in
                isHovering = hovering
                pending?.cancel()
                guard hovering else { isShown = false; return }
                guard delay > 0 else { isShown = true; return }
                pending = Task {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, isHovering else { return }
                    isShown = true
                }
            }
            .onDisappear { pending?.cancel() }
    }
}

public extension View {
    /// Row hover: delayed in, animated out.
    func hoverRow(shape: some Shape = RoundedRectangle(cornerRadius: DS.Radius.md),
                  resting: Color = .clear,
                  hovered: Color = DS.Surface.hover) -> some View {
        modifier(HoverHighlight(shape: AnyShape(shape), resting: resting,
                                hovered: hovered, delay: DS.Motion.hoverRowDelay))
    }

    /// Control hover: immediate, since a control under the cursor is a destination.
    func hoverControl(shape: some Shape = Circle(),
                      resting: Color = DS.Tint.t3,
                      hovered: Color = DS.Tint.t5) -> some View {
        modifier(HoverHighlight(shape: AnyShape(shape), resting: resting,
                                hovered: hovered, delay: 0))
    }

    /// Animate through the reduced-motion chokepoint rather than at the call site.
    func motion<V: Equatable>(_ animation: Animation, value: V,
                              opacityOnly: Bool = false) -> some View {
        modifier(GatedMotion(animation: animation, value: value, opacityOnly: opacityOnly))
    }
}

private struct GatedMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    let opacityOnly: Bool

    func body(content: Content) -> some View {
        content.animation(
            DS.Motion.gated(animation, reduceMotion: reduceMotion, opacityOnly: opacityOnly),
            value: value
        )
    }
}

// MARK: - Delayed spinner

/// A spinner that will not appear before `DS.Motion.spinnerDelay`.
///
/// Anything faster reads as a flicker rather than progress, and most local work finishes inside
/// that window. Showing a spinner for 80 ms makes an app feel *less* responsive, not more,
/// because the eye registers the flash as something going wrong.
public struct DelayedSpinner: View {
    var size: CGFloat = DS.Size.glyph
    var tint: Color = DS.Ink.secondary
    @State private var visible = false

    public init(size: CGFloat = DS.Size.glyph, tint: Color = DS.Ink.secondary) {
        self.size = size; self.tint = tint
    }

    public var body: some View {
        Group {
            if visible { Spinner(size: size, tint: tint) } else { Color.clear }
        }
        .frame(width: size, height: size)
        .task {
            try? await Task.sleep(for: .seconds(DS.Motion.spinnerDelay))
            visible = true
        }
    }
}

// MARK: - Staggered entrance
//
// Removed rather than kept. It was defined, documented at length, and attached to nothing —
// and the note explaining why it must never touch a re-rendering list is the reason it had no
// safe home here: the roster re-renders on every keystroke of search and on every window
// resize, and the transcript re-renders on every streamed token. If a one-time entrance is
// ever wanted, it belongs next to the surface that earns it, with that constraint restated.
