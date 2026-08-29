import SwiftUI
import BotHarnessCore

/// A bot's colour, derived from its stored hue so it is identical every launch.
///
/// Saturation and brightness are fixed by the system; only hue varies. That is what keeps a
/// roster of bots looking like one family rather than a bag of highlighters.
public extension Bot {
    var tint: Color {
        Color(hue: avatar.hue, saturation: 0.58, brightness: 0.90)
    }
}
