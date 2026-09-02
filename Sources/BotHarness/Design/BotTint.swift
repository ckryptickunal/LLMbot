import SwiftUI
import BotHarnessCore

/// A bot's colour, derived from its stored hue so it is identical every launch.
///
/// The stored hue is snapped to the nearest of eight curated anchors rather than used raw.
/// A continuous hue wheel at fixed saturation hands out colours no designer would put side by
/// side — a vivid violet beside a vivid green beside a vivid pink, the bag-of-highlighters
/// roster. Eight anchors were *chosen*, each tuned to sit well beside the clay accent: the warm
/// ones lean into the brand, the cool ones are dusty rather than electric. Determinism survives
/// — the same stored hue snaps to the same anchor forever — and a roster of bots reads as one
/// cast of characters.
///
/// **No purple, and the gap is deliberate.** The old family had a lavender anchor at hue 0.72,
/// which is 259° — squarely violet. Purple, violet and indigo are the single most reliable tell
/// of generated interface work, and the reference system this app's look now follows bans the
/// whole family outright rather than trying to use it tastefully. The anchors below skip the
/// 0.62–0.88 arc entirely, which is why they are spaced the way they are.
///
/// **Both appearances.** These used to be tuned for a dark ground only. A pastel at brightness
/// 0.86 is a solid disc on near-black and a barely-visible smudge on white paper, so each
/// anchor now carries two brightnesses and the disc keeps the same presence either way.
public extension Bot {
    var tint: Color {
        let anchor = Self.family.min {
            Self.wheelDistance($0.hue, avatar.hue) < Self.wheelDistance($1.hue, avatar.hue)
        } ?? Self.family[0]
        return .dynamicHSB(hue: anchor.hue, saturation: anchor.sat,
                           light: anchor.light, dark: anchor.dark)
    }

    /// The eight members. Saturation and brightness vary slightly *per anchor* on purpose —
    /// moss at terracotta's saturation glows radioactive, and a family is colours balanced
    /// against each other, not a formula applied to a wheel.
    ///
    /// `light` is the brightness used on white paper and `dark` the one used on near-black.
    /// Light is always the lower of the two: a colour needs to come *down* to hold an edge
    /// against white and *up* to hold one against black.
    private static let family: [(hue: Double, sat: Double, light: Double, dark: Double)] = [
        (0.045, 0.54, 0.80, 0.85),   // terracotta — the mascot's own corner of the wheel
        (0.105, 0.52, 0.78, 0.87),   // ochre
        (0.155, 0.50, 0.74, 0.86),   // gold
        (0.290, 0.40, 0.66, 0.80),   // moss
        (0.400, 0.36, 0.66, 0.78),   // sage
        (0.480, 0.42, 0.68, 0.82),   // cyan
        (0.575, 0.42, 0.74, 0.86),   // dusty blue
        (0.930, 0.44, 0.80, 0.87),   // rose
    ]

    /// Hue distance on a wheel, where 0.98 and 0.02 are close.
    private static func wheelDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}

extension Color {
    /// An HSB colour whose brightness depends on the appearance drawing it.
    ///
    /// Separate from `Color.dynamic(light:dark:)` because the bot family is authored in HSB —
    /// the hue is the identity and is stored per bot, so converting it to two hex literals
    /// would throw away the one number that has to stay stable.
    static func dynamicHSB(hue: Double, saturation: Double,
                           light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hue: hue, saturation: saturation,
                           brightness: isDark ? dark : light, alpha: 1)
        })
    }
}
