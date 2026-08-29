import SwiftUI

/// The design system, from the bottom up.
///
/// One namespace, `DS`, holding every value the interface is allowed to use. Nothing in a view
/// should contain a raw number or a raw colour — if a view needs a value that is not here, the
/// answer is to add it here and say what it is for, not to write `14` inline. That rule is the
/// whole mechanism: a system is not a palette, it is the absence of exceptions.
///
/// Built for one screen size class (a Mac window), one mode (dark), and one voice (quiet,
/// dense, fast). Read `docs/DESIGN-SYSTEM.md` for the reasoning.
public enum DS {

    // MARK: - Space
    //
    // A 4-point base with a doubling-ish ramp. Every padding, gap and inset comes from here,
    // which is what makes unrelated parts of the app line up without anyone measuring.

    public enum Space {
        public static let hair: CGFloat = 2     // optical nudges only
        public static let xs: CGFloat = 4       // between an icon and its label
        public static let sm: CGFloat = 6       // inside dense chips
        public static let md: CGFloat = 8       // default gap between siblings
        public static let lg: CGFloat = 12      // inside cards
        public static let xl: CGFloat = 16      // between groups
        public static let xxl: CGFloat = 24     // between sections
        public static let xxxl: CGFloat = 40    // page margins, empty states
    }

    // MARK: - Radius
    //
    // Nested corners must differ or the inner one looks wrong: an inner radius should be the
    // outer minus its padding. These four cover every nesting depth the app actually has.

    public enum Radius {
        public static let xs: CGFloat = 4       // inline code, tiny tags
        public static let sm: CGFloat = 6       // fields inside cards
        public static let md: CGFloat = 8       // rows, small cards
        public static let lg: CGFloat = 10      // cards
        public static let xl: CGFloat = 14      // message bubbles
        public static let pill: CGFloat = 999
    }

    // MARK: - Type
    //
    // A six-step scale, tight because this is a dense tool rather than a document. Sizes are
    // in half-points where the optical difference earns it — 12.5 really does read better than
    // 12 or 13 for secondary text at this density.

    public enum Text {
        /// Empty-state titles and nothing else.
        public static let display = Font.system(size: 15, weight: .semibold)
        /// Section and pane titles.
        public static let title = Font.system(size: 13.5, weight: .semibold)
        /// The default. Message bodies, list rows.
        public static let body = Font.system(size: 13)
        /// Supporting text next to a body line.
        public static let secondary = Font.system(size: 12)
        /// Labels, chips, metadata.
        public static let caption = Font.system(size: 11.5)
        /// Timestamps, counters, the smallest thing that should ever be read.
        public static let micro = Font.system(size: 10.5)

        /// Anything the machine wrote: commands, paths, arguments, output.
        public static func mono(_ size: CGFloat = 11.5) -> Font {
            .system(size: size, design: .monospaced)
        }

        /// Line spacing that keeps multi-line body text readable without looking airy.
        public static let bodyLineSpacing: CGFloat = 2.5
    }

    // MARK: - Colour
    //
    // Dark, near-black, low contrast between surfaces and high contrast for text. Surfaces are
    // separated by luminance alone — no borders except where a thing must read as interactive
    // or as a container of something dangerous.
    //
    // Every surface is opaque rather than a white overlay, so stacking two of them cannot
    // produce a third unintended shade.

    public enum Colour {
        // Surfaces, darkest to lightest.
        public static let ground = Color(red: 0.051, green: 0.051, blue: 0.055)
        public static let panel = Color(red: 0.075, green: 0.075, blue: 0.080)
        public static let raised = Color(red: 0.102, green: 0.102, blue: 0.110)
        public static let overlay = Color(red: 0.137, green: 0.137, blue: 0.145)

        // Bubbles read as authorship, so they are the one place with a deliberate step.
        public static let bubbleBot = Color(red: 0.129, green: 0.129, blue: 0.137)
        public static let bubbleUser = Color(red: 0.239, green: 0.239, blue: 0.251)

        // Text, by importance.
        public static let ink = Color.white.opacity(0.93)
        public static let inkSecondary = Color.white.opacity(0.58)
        public static let inkTertiary = Color.white.opacity(0.34)
        public static let inkDisabled = Color.white.opacity(0.20)

        // Lines. Hairlines only; anything heavier reads as a mistake at this density.
        public static let line = Color.white.opacity(0.07)
        public static let lineStrong = Color.white.opacity(0.14)

        // Interactive fills.
        public static let fill = Color.white.opacity(0.055)
        public static let fillHover = Color.white.opacity(0.085)
        public static let fillActive = Color.white.opacity(0.12)
        public static let fillSelected = Color.white.opacity(0.075)

        // Status. Used for dots, pills and icons — never for large areas.
        public static let running = Color(red: 0.98, green: 0.75, blue: 0.30)
        public static let done = Color(red: 0.35, green: 0.85, blue: 0.48)
        public static let failed = Color(red: 0.95, green: 0.44, blue: 0.44)
        public static let waiting = Color(red: 0.45, green: 0.68, blue: 0.98)

        /// Literal values inside prose: paths, addresses, inline code.
        public static let literal = Color(red: 0.98, green: 0.57, blue: 0.49)

        /// The one colour that means "this is the primary action".
        public static let accent = Color.white
        public static let onAccent = ground
    }

    // MARK: - Size
    //
    // Named because they recur, and because a control that is 24 in one place and 26 in another
    // is a bug nobody files.

    public enum Size {
        public static let iconButton: CGFloat = 24
        public static let iconButtonLarge: CGFloat = 28
        public static let avatar: CGFloat = 30
        public static let avatarLarge: CGFloat = 56
        public static let glyph: CGFloat = 12          // icon inside a button
        public static let glyphSmall: CGFloat = 10
        public static let statusDot: CGFloat = 6.5
        public static let rowHeight: CGFloat = 44      // headers and toolbars
        public static let sidebar: CGFloat = 310
        public static let inspector: CGFloat = 340
        public static let bubbleMax: CGFloat = 620
        public static let cardMax: CGFloat = 620
        public static let hairline: CGFloat = 1
    }

    // MARK: - Motion
    //
    // How often a surface appears decides how much animation it earns. Things seen constantly
    // must not perform; things seen rarely may.
    //
    // No `ease-in` anywhere: it delays the first frame, which is the exact moment the eye is
    // on it, and makes an interface feel slower at identical duration.

    public enum Motion {
        /// Custom curves, because the built-in ones are too weak to read as deliberate.
        public static let easeOut = SwiftUI.Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
        public static let easeOutFast = SwiftUI.Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
        public static let easeInOut = SwiftUI.Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)

        /// Seen constantly: a message arriving, a status pill changing, a row highlighting.
        public static let instant = easeOutFast

        /// Seen occasionally: a disclosure, a panel, a sheet.
        public static let surface = easeOut

        /// Seen rarely: first run, an empty state, a celebration.
        public static let rare = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.82)

        /// Press feedback. Buttons must visibly hear the press.
        public static let press = SwiftUI.Animation.easeOut(duration: 0.10)
        public static let pressScale: CGFloat = 0.96

        /// Stagger between items entering together. Short enough not to feel like waiting.
        public static let stagger: Double = 0.035
    }

    // MARK: - Duration
    //
    // Named so that "how long should this take" has one answer per kind of thing.

    public enum Duration {
        public static let press: Double = 0.10
        public static let instant: Double = 0.12
        public static let surface: Double = 0.18
        public static let panel: Double = 0.24
        /// How long a transient confirmation stays before fading.
        public static let toast: Double = 3.0
    }
}

// MARK: - Reduced motion

/// Respecting the system setting is not optional, and it does not mean removing animation —
/// it means removing *movement*. Opacity and colour still carry meaning; sliding and scaling
/// are what cause harm.
public extension View {
    func dsAnimation<V: Equatable>(_ animation: SwiftUI.Animation?, value: V) -> some View {
        modifier(ReducedMotionAware(animation: animation, value: value))
    }
}

private struct ReducedMotionAware<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: SwiftUI.Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.1) : animation, value: value)
    }
}
