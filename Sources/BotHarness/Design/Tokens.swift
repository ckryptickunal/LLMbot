import AppKit
import SwiftUI

/// The design system, implemented. `docs/DESIGN-SYSTEM.md` is the contract; this is the code.
///
/// One namespace, `DS`. Nothing in a view may contain a raw number or a raw colour — if a view
/// needs a value that is not here, the answer is to add it here and say what it is for, not to
/// write `14` inline. That rule is the whole mechanism: a system is not a palette, it is the
/// absence of exceptions.
///
/// ## What changed, and why the old system was wrong
///
/// The app was dark-only, and its structure came entirely from fill against fill: five opaque
/// greys, each a little lighter than the last, stacked to imply depth. The tell is in the old
/// file itself — `Surface.border` and `Surface.borderStrong` were defined, documented, and had
/// **zero call sites**. Nothing in the app drew a line. Every boundary was a change of shade,
/// which is why it read as a stack of soft grey slabs rather than as a built thing.
///
/// Three decisions replace that:
///
/// **Structure comes from hairlines, not from shade.** A card is the page colour with a
/// one-point border, not a lighter rectangle. This is the single change that does most of the
/// work, and it is what makes a surface look drawn rather than lit.
///
/// **Every colour is appearance-aware.** The app follows the system appearance like a Mac app
/// should. The light ramp is the reference's (`#ffffff` paper through `#171717` ink); the dark
/// ramp mirrors it around `#0c0c0c`, and both were checked numerically rather than by eye —
/// every value that carries text clears WCAG AA on its own paper, and the two ramps have
/// matching contrast at matching steps, so a component does not become quieter by being in
/// dark mode.
///
/// **Flat at rest.** No glows, no gradients, no ambient shadow. The old composer had a clay
/// glow behind it and the empty state had a 200-point halo; both are gone. Depth is a border
/// and a tonal fill, and that is the whole vocabulary.
///
/// The neutrals are now true neutral rather than Radix sand. ADR 0022 chose a warm ground
/// because clay on a *cool blue-grey* read as a sticker on someone else's window — that
/// argument was about blue, and true neutral is not blue. Clay sits on it without arguing, and
/// the stage stops having an opinion, which is what a stage is for.
public enum DS {

    // MARK: - Surface
    //
    // The stage. Paper is the page; everything else is a deliberate step away from it.
    //
    // Light values are the reference's neutral ramp. Dark values mirror them: paper is near
    // black rather than pure, because pure black against a Mac's window chrome reads as a hole
    // rather than as a surface, and a hairline on pure black has nowhere to go.

    public enum Surface {
        /// The page. Conversation pane, settings pane, window fills.
        public static let paper = Color.dynamic(light: 0xFFFFFF, dark: 0x0C0C0C)

        /// One step in. Recessed fields at rest, incoming bubbles, disabled fills, the quiet
        /// stripe behind a code block. Never used to imply elevation — it is a *lower* tone,
        /// not a higher one.
        public static let paperTint = Color.dynamic(light: 0xFAFAFA, dark: 0x141414)

        /// A row under the cursor.
        public static let hover = Color.dynamic(light: 0xF5F5F5, dark: 0x1A1A1A)

        /// A selected row. Distinct from `hover` by a full step, because a selected row under
        /// the cursor must still look selected.
        public static let selected = Color.dynamic(light: 0xEDEDED, dark: 0x232323)

        /// A pressed control.
        public static let pressed = Color.dynamic(light: 0xE5E5E5, dark: 0x2B2B2B)

        // Borders. The structural device of the whole system.

        /// Hairline dividers and card edges. Quiet structure — visible, never a line you read.
        public static let borderSubtle = Color.dynamic(light: 0xF0F0F0, dark: 0x1C1C1C)

        /// The default border on a card, a field, a control.
        public static let border = Color.dynamic(light: 0xE5E5E5, dark: 0x262626)

        /// A field the cursor is over, and any border that needs to be seen rather than felt.
        public static let borderStrong = Color.dynamic(light: 0xD4D4D4, dark: 0x333333)

        /// The border of a focused field. Full ink: the reference's focus rule is border colour
        /// and nothing else — never a ring, never a glow.
        public static let borderFocus = Color.dynamic(light: 0x171717, dark: 0xEDEDED)
    }

    // MARK: - Tint
    //
    // Fills for anything drawn *over* a system material — the roster, the inspector, sheets —
    // where an opaque colour would flatten the material into mud.
    //
    // These are neutral now rather than warm ivory, for the same reason the surfaces are, and
    // they are appearance-aware: white alphas over a light material make it *lighter*, which is
    // backwards. Every `Color.white.opacity(…)` in this codebase is still a bug; use these.

    public enum Tint {
        private static let wash = Color.dynamic(light: 0x171717, dark: 0xFFFFFF)

        /// Barely there. A zebra stripe, a disabled fill.
        public static let t2 = wash.opacity(0.022)
        /// Hover fill for a row on a material.
        public static let t3 = wash.opacity(0.045)
        /// A recessed well on a material.
        public static let t4 = wash.opacity(0.070)
        /// A selected row in a window that does not have focus.
        public static let t5 = wash.opacity(0.100)
        /// A separator drawn on a material.
        public static let t6 = wash.opacity(0.130)
        public static let t7 = wash.opacity(0.180)
    }

    // MARK: - Ink
    //
    // Text. The two tiers people actually read stay macOS-semantic, because `labelColor` is an
    // alpha composite rather than a grey and only the semantic name tracks Increase Contrast,
    // desktop tinting and translucency. The quieter tiers are explicit, because at that end the
    // exact value is the design and the system's answer is not the reference's.

    public enum Ink {
        /// Everything the user actually reads. 17.9:1 light, 16.7:1 dark.
        public static let primary = Color.primary
        /// Supporting text that is still meant to be read.
        public static let secondary = Color.secondary

        /// The reference's `muted`. Secondary prose, footers, help text — 4.7:1 light,
        /// 6.1:1 dark, so it is quiet but still legitimately readable.
        public static let muted = Color.dynamic(light: 0x737373, dark: 0x8F8F8F)

        /// The reference's `faint`. Placeholders, meta labels, keyboard hints.
        /// **Never a string the user must read.**
        public static let tertiary = Color.dynamic(light: 0xA3A3A3, dark: 0x6B6B6B)

        /// Glyph washes and other non-text marks.
        public static let quaternary = Color.dynamic(light: 0xD4D4D4, dark: 0x3A3A3A)

        /// Ink drawn on an ink-filled control — a primary button's label.
        public static let onInk = Color.dynamic(light: 0xFFFFFF, dark: 0x0C0C0C)

        /// The fill of a primary control. Ink-soft rather than full ink, so a button feels
        /// solid without shouting.
        public static let fill = Color.dynamic(light: 0x262626, dark: 0xEDEDED)
        /// The same fill, hovered — deepens toward ink.
        public static let fillHover = Color.dynamic(light: 0x171717, dark: 0xFFFFFF)
    }

    // MARK: - Accent
    //
    // The mascot's clay (ADR 0022), kept as the app's single accent and demoted to accent duty.
    //
    // The reference's One Voice Rule is the reason for the demotion: the stage stays neutral and
    // colour lives in state and in signature moments, never in chrome. So clay is no longer the
    // selection colour, no longer the focus ring, and no longer a wash behind a hero avatar. It
    // is the character, the send button the character stands beside, and nothing else — which is
    // both under the reference's ten-per-cent bar and a stronger identity than spraying it
    // everywhere was.

    public enum Accent {
        /// The clay fill. Send button, mascot, brand marks. Identical in both appearances,
        /// because it is a brand colour rather than a neutral.
        public static let live = Color(hex: 0xDD775B)

        /// Clay as *text or a mark*, which the fill colour cannot be: `#DD775B` measures 3.06:1
        /// on white and fails AA outright. This is the same hue taken down until it passes —
        /// 5.09:1 on light paper, and on dark the fill is already 6.39:1 and needs no change.
        public static let text = Color.dynamic(light: 0xB4502F, dark: 0xDD775B)

        /// Ink drawn *on* a clay fill. Warm near-black, because white on this clay measures
        /// 3.1:1 and fails; this measures 5.3:1.
        public static let onAccent = Color(hex: 0x2B1811)

        /// A clay hairline, for the one or two places a border should carry the brand.
        public static let border = live.opacity(0.55)
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
    // **Never colour alone**: every status is a glyph plus a word plus a colour, so it survives
    // colour-blindness and a greyscale screenshot.
    //
    // Both ramps were measured against their own paper and every mark clears AA as text, which
    // is a stricter bar than a dot needs and the right one for the word beside it. The old dark
    // values were Radix step 9, authored for dark grounds and unreadable on white — amber9 on
    // paper is 1.7:1.
    //
    // The one rule with a real cost if broken: `running` and `awaitingApproval` must never share
    // a colour. "Working" and "blocked on you" is the confusion in this app that wastes a
    // person's afternoon.

    public enum Status: String, CaseIterable, Sendable {
        case idle, running, awaitingApproval, done, failed, waiting, denied

        /// The dot, the bar and the word. One value rather than the old mark/label pair: with
        /// both ramps tuned to clear AA on their own paper, a second, lighter variant was a
        /// second thing to keep in step for no gain.
        public var mark: Color {
            switch self {
            case .idle:             return Color.dynamic(light: 0x737373, dark: 0x8F8F8F)
            case .running:          return Color.dynamic(light: 0xB45309, dark: 0xFFC53D)
            case .awaitingApproval: return Color.dynamic(light: 0xC2410C, dark: 0xF97316)
            case .done:             return Color.dynamic(light: 0x15803D, dark: 0x4ADE80)
            case .failed, .denied:  return Color.dynamic(light: 0xB91C1C, dark: 0xF87171)
            case .waiting:          return Color.dynamic(light: 0x1D4ED8, dark: 0x60A5FA)
            }
        }

        /// The word beside the mark. Idle stays secondary so an idle bot does not advertise
        /// itself; everything else carries its own colour.
        public var label: Color {
            switch self {
            case .idle: return Color.secondary
            default:    return mark
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

        /// The tinted chip behind the label. A wash of the mark rather than a hand-picked
        /// third colour, so a chip can never drift out of step with the dot it sits beside.
        public var chip: Color {
            self == .idle ? Surface.paperTint : mark.opacity(0.10)
        }

        /// The chip's hairline. Chips are bordered like everything else now, which is what lets
        /// them sit on paper at a ten-per-cent fill and still read as objects.
        public var chipBorder: Color {
            self == .idle ? Surface.border : mark.opacity(0.24)
        }
    }

    // MARK: - Type
    //
    // One voice, SF Pro, and hierarchy made out of size, weight and tracking rather than out of
    // a second typeface.
    //
    // The reference pairs a display serif with a sans. This app does not: **no serif**, by
    // instruction, and the substitution is not a compromise so long as the display step does
    // the work the serif was doing. What made the serif read as a brand moment was that it was
    // *set* rather than merely large — so the display and headline steps carry negative
    // tracking, which is the same move the reference already makes on its own body copy
    // (`letterSpacing: -0.025em`). Large sans at default tracking is the thing that looks
    // undesigned; large sans pulled tight does not.
    //
    // `design: .rounded` and `design: .serif` are both banned — the first has no macOS
    // precedent and reads instantly as non-native, the second is out by instruction.

    public enum Text {
        /// The one big moment per screen. An empty conversation's bot name.
        public static let display = Font.system(size: 28, weight: .semibold)
        /// Section titles and pane headings.
        public static let headline = Font.system(size: 19, weight: .semibold)

        /// Tracking for the two steps above. Negative, and that is the whole trick: SF Pro
        /// spaces itself for reading at body size, so at 28 points the default gaps are what
        /// make a heading look like body text that was scaled up.
        public static let displayTracking: CGFloat = -0.7
        public static let headlineTracking: CGFloat = -0.4

        /// Message text, row labels, field text.
        public static let body = Font.body
        /// Card titles, sidebar section labels, form labels. "Body Emphasized" in the HIG.
        public static let title = Font.body.weight(.semibold)
        /// Supporting text beside a body line.
        public static let callout = Font.callout
        /// Chips, metadata, settings help text.
        public static let caption = Font.subheadline
        /// Timestamps, counters, hash prefixes.
        public static let micro = Font.caption

        /// A label above a field or a group. Small, medium weight, slightly tracked out — the
        /// reference's `label` step, and the thing that makes a settings pane look composed
        /// rather than listed.
        public static let label = Font.caption.weight(.medium)
        public static let labelTracking: CGFloat = 0.3

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
        /// Page margins and empty states. 48 rather than 40, matching the reference's top
        /// step — the extra eight points is most of what makes an empty state look composed.
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Radius
    //
    // The reference's three steps — 6 for controls, 8 for fields, 16 for cards — plus the two
    // small ones this app already needed.
    //
    // Nesting rule, and it is not optional: **inner radius = outer radius − inner padding.**
    // A 16pt card with 8pt of padding contains an 8pt element. Nested corners that share a
    // radius look wrong in a way people notice without being able to name.

    public enum Radius {
        public static let xs: CGFloat = 4       // inline code, tags
        public static let sm: CGFloat = 6       // buttons, chips
        public static let md: CGFloat = 8       // fields, rows
        public static let lg: CGFloat = 12      // small cards
        public static let xl: CGFloat = 16      // cards, bubbles, sheets
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
        /// Text control heights, so a field and a button beside it share a baseline. The
        /// reference's controls are 40pt tall, which is a web number; 28 is the Mac one and
        /// what the toolbar beside it uses.
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
        /// Tool cards, approval cards, connection rows. Sixteen on every side, which is the
        /// reference's card padding and reads as deliberate where the old 12/13 read as tight.
        public static let card = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
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
        /// Strong ease-out. The built-in curves are too weak to read as intentional. This is
        /// the reference's `--ease-smooth` to three decimal places, arrived at independently.
        private static func out(_ duration: Double) -> Animation {
            .timingCurve(0.22, 1, 0.36, 1, duration: duration)
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
    /// sRGB from a hex literal, for the values published that way.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }

    /// A colour that resolves against whichever appearance is drawing it.
    ///
    /// `NSColor(name:dynamicProvider:)` rather than an asset catalogue, because this package has
    /// no asset catalogue and a hand-assembled bundle should not grow one to hold forty colours
    /// that are already written down here. The provider is asked at draw time, so a value built
    /// once at launch still flips when the user changes appearance in System Settings.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
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
