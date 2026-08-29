import BotHarnessCore
import SwiftUI

/// The visual system.
///
/// Dark by default and dark by preference: this is a tool that sits open beside a terminal
/// and an editor. Colours are defined once here so that "what grey is that" has one answer.
///
/// The target feel is Grok Bot's — near-black ground, low-contrast panels, a single accent
/// used sparingly — reached with native SwiftUI materials rather than by hand-painting
/// hex values everywhere.
enum Theme {

    // MARK: Surfaces

    /// The window ground. Nearly black, not black: pure black on an OLED-adjacent display
    /// makes the panel seams disappear and the layout stop reading as layered.
    static let ground = Color(red: 0.055, green: 0.055, blue: 0.059)

    /// Sidebar and context panel.
    static let panel = Color(red: 0.078, green: 0.078, blue: 0.082)

    /// A bot's message bubble.
    static let bubbleBot = Color(red: 0.145, green: 0.145, blue: 0.153)

    /// The user's message bubble — lighter, so authorship is legible without reading.
    static let bubbleUser = Color(red: 0.255, green: 0.255, blue: 0.267)

    /// Cards: tool activity, the Computer card, approval prompts.
    static let card = Color(red: 0.106, green: 0.106, blue: 0.114)

    static let separator = Color.white.opacity(0.07)

    // MARK: Text

    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    /// Inline code and email addresses. Grok Bot uses a salmon; it reads as "literal value"
    /// without shouting.
    static let literal = Color(red: 0.98, green: 0.55, blue: 0.47)

    // MARK: Status

    static let running = Color(red: 0.98, green: 0.75, blue: 0.30)
    static let done = Color(red: 0.35, green: 0.85, blue: 0.48)
    static let failed = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let waiting = Color(red: 0.45, green: 0.68, blue: 0.98)

    // MARK: Metrics

    static let sidebarWidth: CGFloat = 310
    static let contextWidth: CGFloat = 340
    static let bubbleRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10

    /// Maximum width of a message bubble as a fraction of the conversation column, so that
    /// long prose does not run to unreadable line lengths on a wide window.
    static let bubbleMaxFraction: CGFloat = 0.72
}

extension Bot {
    /// Deterministic colour from the stored hue, so a bot looks the same every launch.
    var tint: Color {
        Color(hue: avatar.hue, saturation: 0.62, brightness: 0.92)
    }
}

/// Motion.
///
/// Borrowed from the frequency principle already used in Fable: how often a surface appears
/// determines how much animation it earns. Things you see constantly must not perform.
enum Motion {
    /// Constant surfaces — a message arriving, a status pill changing. Near-instant.
    static let routine = Animation.easeOut(duration: 0.12)

    /// Occasional surfaces — a panel opening, a view changing.
    static let occasional = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Rare surfaces — first run, an empty state. May delight.
    static let rare = Animation.spring(response: 0.55, dampingFraction: 0.72)
}
