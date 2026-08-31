import SwiftUI
import BotHarnessCore

/// A bot's colour, derived from its stored hue so it is identical every launch.
///
/// The stored hue is snapped to the nearest of eight curated anchors rather than used raw.
/// A continuous hue wheel at fixed saturation hands out colours no designer would put side by
/// side — a vivid violet beside a vivid green beside a vivid pink, the bag-of-highlighters
/// roster. Eight anchors were *chosen*, each tuned to sit well beside the clay accent and the
/// sand surfaces: the warm ones lean into the brand, the cool ones are dusty rather than
/// electric. Determinism survives — the same stored hue snaps to the same anchor forever —
/// and a roster of bots reads as one cast of characters.
public extension Bot {
    var tint: Color {
        let anchor = Self.family.min {
            Self.wheelDistance($0.hue, avatar.hue) < Self.wheelDistance($1.hue, avatar.hue)
        } ?? Self.family[0]
        return Color(hue: anchor.hue, saturation: anchor.sat, brightness: anchor.bri)
    }

    /// The tint at halo strength, for the soft wash behind a hero avatar. Owned here so the
    /// one opacity that pairs with the family lives beside the family.
    var halo: Color { tint.opacity(0.16) }

    /// The eight members. Saturation and brightness vary slightly *per anchor* on purpose —
    /// olive at terracotta's saturation glows radioactive, and a family is colours balanced
    /// against each other, not a formula applied to a wheel.
    private static let family: [(hue: Double, sat: Double, bri: Double)] = [
        (0.045, 0.54, 0.85),   // terracotta — the mascot's own corner of the wheel
        (0.100, 0.52, 0.87),   // ochre
        (0.210, 0.38, 0.78),   // olive
        (0.400, 0.36, 0.78),   // sage
        (0.510, 0.44, 0.80),   // teal
        (0.600, 0.40, 0.86),   // dusty blue
        (0.720, 0.36, 0.86),   // lavender
        (0.920, 0.44, 0.87),   // rose
    ]

    /// Hue distance on a wheel, where 0.98 and 0.02 are close.
    private static func wheelDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}
