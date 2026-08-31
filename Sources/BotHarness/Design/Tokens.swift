import SwiftUI

/// The design system, implemented. `docs/DESIGN-SYSTEM.md` is the contract; this is the code.
///
/// One namespace, `DS`. Nothing in a view may contain a raw number or a raw colour — if a view
/// needs a value that is not here, the answer is to add it here and say what it is for, not to
/// write `14` inline. That rule is the whole mechanism: a system is not a palette, it is the
/// absence of exceptions.
///
/// Three decisions shape everything below, and each was a real fork:
///
/// **Colour comes from two places, not one.** Radix Colors (MIT) supplies the opaque neutral
/// ramp, because macOS publishes no numeric surface scale — you get `windowBackground`,
/// `controlBackground`, `underPageBackground` and nothing between, and a three-pane cockpit
/// needs five distinguishable depths. macOS supplies text and materials, because `labelColor`
/// is white at 84.7% alpha rather than a grey, and only an alpha composite tracks Increase
/// Contrast, desktop tinting and translucency correctly. The accent is the one deliberate
/// exception to "macOS owns it": it is the mascot's clay (ADR 0022), because the app has a
/// character and a character wears one colour.
///
/// **The functional layer is never painted; the content layer always is.** The roster, the
/// inspector, the toolbar and every sheet get no background at all and inherit the system
/// material. Only the conversation pane is filled. This single rule decides whether the app
/// reads as Mac-native or as a web page in a window.
///
/// **We do not copy Grok Bot's pixels.** Their palette is flat achromatic Electron grey
/// (#070707 / #111111 / #262626) with no semantic contract and no alpha companion. We take
/// their information design — the bubble geometry, the natural-language rule form, the handoff
/// card, the settings copy — and leave the greys.
public enum DS {

    // MARK: - Surface
    //
    // Radix sand, dark, steps 1-8. Opaque. For the content layer only: anything drawn over a
    // system material must use `DS.Tint` instead, or it flattens the material into mud.
    //
    // The 12 Radix steps are a semantic contract rather than a lightness ramp, which is why
    // this is the base: step 3 is an element background, 6 a subtle border, 9 a solid fill,
    // 11 low-contrast text. The scale tells you which value to use.
    //
    // Sand rather than slate, and the swap is the identity decision of the app (ADR 0022):
    // the accent and the mascot are warm clay, and clay on a cool blue-grey ground reads as a
    // sticker on someone else's window. The warm neutral is what makes the character look like
    // it lives here. Same Radix contract, same steps — only the temperature changed.

    public enum Surface {
        /// sand1 — the conversation pane, the Settings content pane.
        /// Deliberately *darker* than the window chrome, which is the native relationship.
        public static let ground = Color(hex: 0x111110)
        /// sand2 — composer field, inset wells inside the transcript.
        public static let panel = Color(hex: 0x191918)
        /// sand3 — cards, incoming bubbles, tool cards, settings cards.
        public static let raised = Color(hex: 0x222221)
        /// sand4 — a hovered card or row sitting on an opaque surface.
        public static let raisedHover = Color(hex: 0x2A2A28)
        /// sand5 — pressed or selected element on an opaque surface; the outgoing bubble.
        public static let active = Color(hex: 0x31312E)
        /// sand6 — subtle borders and dividers inside cards.
        public static let border = Color(hex: 0x3B3A37)
        /// sand7 — field borders.
        public static let borderStrong = Color(hex: 0x494844)
    }

    // MARK: - Tint
    //
    // Sand alphas, steps A2-A7. For anything drawn *over* a system material — the roster, the
    // inspector, the toolbar, sheets.
    //
    // Note these are not pure white. The base is a warm ivory, the alpha companion to the sand
    // surfaces, so a tint over a material and a surface beside it read as one temperature. The
    // cast is deliberate and small — at these opacities it warms without ever reading as
    // yellow. Every `Color.white.opacity(…)` in this codebase is a bug; use these.

    public enum Tint {
        private static let warm = Color(hex: 0xF2EDE3)

        public static let t2 = warm.opacity(0.035)
        /// Hover fill for a row sitting on a material.
        public static let t3 = warm.opacity(0.078)
        public static let t4 = warm.opacity(0.114)
        /// A selected row in a window that does not have focus.
        public static let t5 = warm.opacity(0.145)
        /// A separator drawn on a material.
        public static let t6 = warm.opacity(0.188)
        public static let t7 = warm.opacity(0.251)
    }

    // MARK: - Ink
    //
    // Text. macOS semantic, never Radix — `labelColor` is white at 84.7% alpha, not a grey,
    // and only the semantic name tracks Increase Contrast and desktop tinting.
    //
    // Prefer `.foregroundStyle(.primary)` and friends directly in views. These exist for the
    // handful of places that need a `Color` value rather than a `ShapeStyle`.

    public enum Ink {
        /// 13.6:1 on `ground`. Everything the user actually reads.
        public static let primary = Color.primary
        /// 6.2:1. Supporting text that is still meant to be read.
        public static let secondary = Color.secondary
        /// 2.2:1 — decorative and disabled only. **Never a string the user must read.**
        public static let tertiary = Color.primary.opacity(0.247)
        /// Glyph washes and other non-text marks.
        public static let quaternary = Color.primary.opacity(0.098)

    }

    // MARK: - Accent
    //
    // The mascot's clay, promoted to the app's accent (ADR 0022). This deliberately does NOT
    // track `controlAccentColor` any more: the character standing on the composer, the send
    // button beside it and the selection in the roster are one identity, and an app whose
    // mascot is clay while its buttons follow whatever System Settings says wears two brands
    // at once. The cost — ignoring the user's accent preference — is the decision.

    public enum Accent {
        /// Selection, primary actions, focus. The same clay as `Brand.mascot`, on purpose.
        public static let live = Color(hex: 0xDD775B)

        /// Ink drawn *on* an accent fill. Dark, like the avatars' monograms, because white on
        /// this clay measures 3.1:1 and fails AA — this warm near-black measures 5.3:1.
        public static let onAccent = Color(hex: 0x2B1811)

        /// The composer's border while focused. Quiet on purpose: the composer is focused
        /// almost always, so anything louder would be permanent decoration.
        public static let ring = live.opacity(0.45)

        /// The soft glow under the focused composer. Barely there; it reads as warmth, not
        /// as a highlight.
        public static let ringGlow = live.opacity(0.12)

        /// A wash for selected fills and the halo behind a hero avatar.
        public static let wash = live.opacity(0.14)
    }

    // MARK: - Brand
    //
    // The mascot's own colours. `mascot` and `Accent.live` are the same value and that is the
    // point — the character *is* the accent. They stay separate names because they answer
    // different questions: Brand is "what colour is the drawing", Accent is "what colour is
    // an action", and the day a rebrand splits them the call sites are already sorted.

    public enum Brand {
        /// The mascot's clay, taken from the source SVG rather than sampled from a screenshot.
        public static let mascot = Color(hex: 0xDD775B)

        /// Flat black in every frame of the original, including over dark grounds. It reads
        /// because it sits on the clay, never on the app's background.
        public static let mascotEye = Color.black
    }

    // MARK: - Status
    //
    // Radix step 9 for the dot, step 11 for the word beside it. **Never colour alone**: every
    // status is a glyph plus a word plus a colour, so it survives colour-blindness and a
    // greyscale screenshot.
    //
    // The one rule with a real cost if broken: `running` and `awaitingApproval` must never
    // share a colour. "Working" and "blocked on you" is the confusion in this app that wastes
    // a person's afternoon.

    public enum Status: String, CaseIterable, Sendable {
        case idle, running, awaitingApproval, done, failed, waiting, denied

        /// The dot or bar. Radix step 9.
        public var mark: Color {
            switch self {
            case .idle:             return Color(hex: 0x696e77)   // slate9
            case .running:          return Color(hex: 0xffc53d)   // amber9
            case .awaitingApproval: return Color(hex: 0xf76b15)   // orange9
            case .done:             return Color(hex: 0x30a46c)   // green9
            case .failed, .denied:  return Color(hex: 0xe5484d)   // red9
            case .waiting:          return Color(hex: 0x0090ff)   // blue9
            }
        }

        /// The word beside it. Radix step 11 — the step authored to be readable on a dark
        /// background, all of these ≥9:1 on `ground`.
        public var label: Color {
            switch self {
            case .idle:             return Color.secondary
            case .running:          return Color(hex: 0xffca16)   // amber11
            case .awaitingApproval: return Color(hex: 0xffa057)   // orange11
            case .done:             return Color(hex: 0x3dd68c)   // green11
            case .failed, .denied:  return Color(hex: 0xff9592)   // red11
            case .waiting:          return Color(hex: 0x70b8ff)   // blue11
            }
        }

        public var glyph: String {
            switch self {
            case .idle:             return "circle"
            case .running:          return "circle.dotted"
            case .awaitingApproval: return "hand.raised.fill"
            case .done:             return "checkmark.circle.fill"
            case .failed:           return "xmark.octagon.fill"
            case .waiting:          return "clock"
            case .denied:           return "nosign"
            }
        }

        public var word: String {
            switch self {
            case .idle:             return "Idle"
            case .running:          return "Running"
            case .awaitingApproval: return "Needs you"
            case .done:             return "Done"
            case .failed:           return "Failed"
            case .waiting:          return "Waiting"
            case .denied:           return "Blocked"
            }
        }

        /// A tinted chip behind the label, all ≥7:1.
        public var chip: Color {
            switch self {
            case .idle:             return Surface.raised
            case .running:          return Color(hex: 0x302008)   // amber3
            case .awaitingApproval: return Color(hex: 0x331e0b)   // orange3
            case .done:             return Color(hex: 0x132d21)   // green3
            case .failed, .denied:  return Color(hex: 0x3b1219)   // red3
            case .waiting:          return Color(hex: 0x0d2847)   // blue3
            }
        }
    }

    // MARK: - Type
    //
    // Five steps, each bound to a system text style so they track the OS and line up optically
    // with the toolbar. The previous scale had six half-point sizes appearing 31 times; they
    // match nothing the system draws, which is exactly why the text never sat right.
    //
    // `design: .rounded` is banned — it has no macOS precedent and reads instantly as
    // non-native.

    public enum Text {
        /// Message text, row labels, field text.
        public static let body = Font.body
        /// Section and pane titles, the bot name in the header. "Body Emphasized" in the HIG.
        public static let title = Font.body.weight(.semibold)
        /// Supporting text beside a body line.
        public static let callout = Font.callout
        /// Chips, metadata, settings help text.
        public static let caption = Font.subheadline
        /// Timestamps, counters, hash prefixes.
        public static let micro = Font.caption

        /// Shell commands, tool arguments, paths, trace hashes. **The only correct use of
        /// monospace in this app** — prose in monospace is a web habit, not a Mac one.
        public static let mono = Font.body.monospaced()
        public static let monoSmall = Font.subheadline.monospaced()

        /// Multi-line prose only. Single-line labels must not carry it.
        public static let bodyLineSpacing: CGFloat = 2.5

        // Glyph sizes, as fonts. SF Symbols are text, so they take a font rather than a frame;
        // `DS.Size.glyph` is the matching frame length for when one is needed to reserve space.
        public static let glyph = Font.system(size: 12)
        public static let glyphSmall = Font.system(size: 10)
        public static let glyphBold = Font.system(size: 10, weight: .semibold)

    }

    // MARK: - Space
    //
    // A 4-point base. Every padding, gap and inset comes from here, which is what makes
    // unrelated parts of the app line up without anyone measuring.

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
    // Nesting rule, and it is not optional: **inner radius = outer radius − inner padding.**
    // A 12pt card with 8pt of padding contains a 4pt element. Nested corners that share a
    // radius look wrong in a way people notice without being able to name.

    public enum Radius {
        public static let xs: CGFloat = 4       // inline code, tags
        public static let sm: CGFloat = 6       // fields inside cards
        public static let md: CGFloat = 8       // rows, small cards
        public static let lg: CGFloat = 12      // cards, tool cards, handoff cards
        public static let xl: CGFloat = 16      // message bubbles, sheets
        public static let pill: CGFloat = 999

    }

    // MARK: - Size
    //
    // Native metrics, measured on macOS 26.5. Row heights are four different numbers on
    // purpose: a dense activity row and a settings row with help text are not the same
    // component and should not pretend to be.

    public enum Size {
        public static let iconButton: CGFloat = 24
        public static let avatarRoster: CGFloat = 24
        public static let avatarInspector: CGFloat = 64
        public static let glyph: CGFloat = 12
        /// The large glyph an empty state or a drop target draws.
        public static let glyphHero: CGFloat = 22
        public static let glyphSmall: CGFloat = 10
        public static let statusDot: CGFloat = 6

        /// The mascot, on its strip above the composer.
        ///
        /// **The only mascot number.** Everything else follows from it: the strip's height
        /// comes from `Mascot.stageHeight(width:)`, because the walk needs headroom for the
        /// jump that no separate constant should have to be kept in step with, and how far it
        /// walks comes from `Mascot.travel(inStageWidth:)`, so the stride stays the right
        /// length instead of stretching to whatever the composer happens to be. Change this
        /// and the rest re-proportions itself.
        public static let mascot: CGFloat = 22

        public static let denseRow: CGFloat = 24        // activity and trace rows
        public static let rosterRow: CGFloat = 28       // avatar plus two lines
        public static let connectionRow: CGFloat = 32
        public static let settingsRow: CGFloat = 44     // minimum; auto-height with help text

        public static let titlebar: CGFloat = 52
        public static let bubbleMax: CGFloat = 620
        /// The widest a column of prose may get before it stops being comfortable to read.
        /// Used by `ReadingColumn`.
        public static let readingMax: CGFloat = 720
        public static let cardMax: CGFloat = 640
        public static let hairline: CGFloat = 1

        // Minimums. A component that does not declare its own floor is a component a parent
        // can squash, and every squashed control in this app so far was one that had not said
        // how small it was willing to get.

        /// Smallest comfortable pointer target. Anything under this is a control people miss.
        public static let hit: CGFloat = 28
        /// Holds the status pill's geometry still as "Running" becomes "Done".
        public static let statusPillMin: CGFloat = 62
        /// Text control heights, so a field and a button beside it share a baseline.
        public static let controlHeight: CGFloat = 28
        /// A field stops being usable below this and should truncate rather than shrink.
        public static let fieldMin: CGFloat = 120
        /// Bubbles and cards never get narrower than this; below it, text wraps to one word
        /// a line and the layout looks broken rather than tight.
        public static let bubbleMin: CGFloat = 64
        public static let cardMin: CGFloat = 180
        /// Composer growth bounds.
        public static let composerMin: CGFloat = 36
        /// Screenshot cards in the transcript.
        public static let screenshotMin: CGFloat = 200
        public static let screenshotMax: CGFloat = 460
        /// The activity stream is a peek, not a second transcript.
        public static let activityStreamMax: CGFloat = 220
        /// The soft halo behind the hero avatar in an empty conversation.
        public static let halo: CGFloat = 200
        /// Blur radius of the focused composer's glow.
        public static let glowRadius: CGFloat = 12

        // Split-view columns. Resizable ranges, not the fixed Electron numbers Grok Bot uses.
        public static let rosterMin: CGFloat = 180
        public static let rosterIdeal: CGFloat = 240
        public static let rosterMax: CGFloat = 320
        /// Below this the transcript stops being readable, so it is what the other two
        /// columns have to yield to.
        public static let conversationMin: CGFloat = 420
        public static let inspectorMin: CGFloat = 260
        public static let inspectorIdeal: CGFloat = 300
        public static let inspectorMax: CGFloat = 380
    }

    // MARK: - Window
    //
    // Window and sheet dimensions. These were the last raw numbers in the app, and they are
    // the ones that matter most: a sheet 40 points too short clips its own content, and
    // nobody notices until a connector name is long.

    public enum Window {
        /// Main window default. Wide enough for roster, transcript and inspector at once.
        public static let mainWidth: CGFloat = 1280
        public static let mainHeight: CGFloat = 820
        /// Floor for the main window: roster plus a readable transcript, nothing narrower.
        public static let mainMinHeight: CGFloat = 520

        /// The activity window is a two-pane reader, so it needs more width than a sheet.
        public static let activityWidth: CGFloat = 980
        public static let activityHeight: CGFloat = 620
        public static let activityMinWidth: CGFloat = 820
        public static let activityListMin: CGFloat = 260
        public static let activityListIdeal: CGFloat = 300
        public static let activityListMax: CGFloat = 380
        public static let activityDetailMin: CGFloat = 460

        /// Settings and the library share one size, so switching between them does not resize.
        ///
        /// 620 rather than 480, measured against the tab that holds the most: Connections opens
        /// on a description line, a section label and five capability rows, which came to more
        /// than 480 and left the fifth row sliced through the middle at the sheet's edge. The
        /// comment above this block already warned that a sheet forty points too short clips its
        /// own content; this one was a hundred and forty short.
        public static let sheetWidth: CGFloat = 560
        public static let sheetHeight: CGFloat = 620

        /// A popover menu wide enough that no item wraps.
        public static let popoverMin: CGFloat = 190

        /// Full-size screenshot viewer.
        public static let viewerMinWidth: CGFloat = 720
        public static let viewerMinHeight: CGFloat = 480

        /// The persona paragraph in an empty conversation.
        public static let proseMax: CGFloat = 420
        /// The Computer card, which is narrower than a full card on purpose: it is a status
        /// object, not a body of text.
        public static let computerCardMax: CGFloat = 400
        /// The bot description editor.
        public static let personaEditorHeight: CGFloat = 130
    }

    // MARK: - Inset
    //
    // Component padding, named rather than assembled from scale steps at the call site.
    // "DS.Space.lg - 1" is a literal wearing a token's clothes, and it is how a layout ends up
    // with eleven slightly different bubble paddings.

    public enum Inset {
        /// Message bubbles. Wider than tall, so a single line reads as a lozenge rather than
        /// a box, which is what makes a transcript feel like a conversation.
        public static let bubble = EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15)
        /// Tool cards, approval cards, connection rows.
        public static let card = EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13)
        /// Roster rows and list rows.
        public static let row = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        /// The composer field.
        public static let composer = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 9)
        /// A pane's own outer margin.
        public static let pane = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
    }

    // MARK: - Motion
    //
    // Frequency-gated, which is the one organising rule Apple's HIG and Emil Kowalski arrive at
    // independently: how often a control is touched decides whether it animates at all.
    // Anything triggered by a keyboard shortcut animates never.
    //
    // Every value passes through `gated` so reduced-motion is handled once rather than at
    // ninety call sites.

    public enum Motion {
        /// Strong ease-out. The built-in curves are too weak to read as intentional.
        private static func out(_ duration: Double) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: duration)
        }

        /// Button press. Pair with `pressScale`.
        public static let press = out(0.10)
        public static let pressScale: CGFloat = 0.97

        /// Hover in is *instant* — set the value directly, do not animate. Only the exit
        /// animates. The asymmetry is the point: a cursor crossing a list should not trail
        /// glow behind it.
        public static let hoverOut = out(0.12)
        /// Rows wait this long before showing hover, so a cursor traversing the roster does
        /// not strobe. Buttons get no delay.
        public static let hoverRowDelay: Double = 0.070

        /// Status pill, token count, row highlight, pane crossfade.
        public static let instant = out(0.12)
        /// A control that just became available — the send button filling in. A small spring
        /// with a small bounce: the state change carries the user's own momentum (they just
        /// typed), which is the one licence for overshoot, and it fires constantly, which is
        /// why the overshoot is barely there.
        public static let pop = Animation.spring(duration: 0.30, bounce: 0.18)
        /// One full sweep of the thinking shimmer. Slow enough to read as breathing, not
        /// as a progress bar.
        public static let shimmerPeriod: Double = 1.6
        /// Expand and collapse. The chevron rotates on the same curve.
        public static let disclosure = out(0.18)
        /// Transcript and activity row insertion.
        public static let rowInsert = out(0.20)
        /// Inspector slide.
        public static let panel = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)

        /// First five items only; zero thereafter. A long staggered list is just slow.
        public static let stagger: Double = 0.035
        public static let staggerLimit = 5

        /// No spinner may appear before this. Anything faster reads as a flicker, not progress.
        public static let spinnerDelay: Double = 0.400
        /// How long a transient confirmation stays before fading. Long enough to notice,
        /// short enough not to become furniture.
        public static let confirmationDwell: Double = 3.0

        /// The single chokepoint for reduced motion.
        ///
        /// Returns nil — meaning "apply the change with no animation" — except for
        /// opacity-only crossfades, which stay because they aid comprehension rather than
        /// implying movement. Reduced motion means fewer and gentler animations, not none.
        public static func gated(_ animation: Animation, reduceMotion: Bool,
                                 opacityOnly: Bool = false) -> Animation? {
            guard reduceMotion else { return animation }
            return opacityOnly ? out(0.12) : nil
        }
    }
}

// MARK: - Colour helpers

extension Color {
    /// sRGB from a hex literal, for the Radix values published that way.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }

    /// Display P3, which is what Radix authors and what every Mac display renders.
    init(p3 red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) {
        self.init(.displayP3, red: red, green: green, blue: blue, opacity: opacity)
    }
}

// MARK: - Applying motion

extension View {
    /// Animate through the reduced-motion gate rather than around it.
    public func dsAnimation<V: Equatable>(_ animation: Animation, value: V,
                                          opacityOnly: Bool = false) -> some View {
        modifier(GatedAnimation(animation: animation, value: value, opacityOnly: opacityOnly))
    }
}

private struct GatedAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    let opacityOnly: Bool

    func body(content: Content) -> some View {
        content.animation(DS.Motion.gated(animation, reduceMotion: reduceMotion,
                                          opacityOnly: opacityOnly),
                          value: value)
    }
}
