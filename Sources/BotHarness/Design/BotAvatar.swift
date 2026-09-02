import BotHarnessCore
import SwiftUI

/// A bot's mark.
///
/// One component, because a bot appears in the roster, the header, the empty state and the
/// inspector, and four hand-rolled circles is how four slightly different avatars happen.
///
/// A monogram rather than a bare disc: a flat coloured circle reads as a placeholder that
/// somebody forgot to replace, and the initial costs nothing to draw.
public struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = DS.Size.avatarRoster

    public init(bot: Bot, size: CGFloat = DS.Size.avatarRoster) {
        self.bot = bot; self.size = size
    }

    public var body: some View {
        Circle()
            // Flat, not `.gradient`. A gradient on a 24-point disc is invisible as a gradient
            // and visible as softness, and softness is what this system spent its whole rewrite
            // removing — nothing else in the app is shaded, so one shaded thing reads as a
            // leftover.
            .fill(bot.tint)
            .frame(width: size, height: size)
            .overlay {
                Text(monogram)
                    // Not `.rounded`: the type tokens ban it outright — it has no macOS
                    // precedent and reads instantly as non-native — and a monogram is the one
                    // place a stray typeface is most visible, since it sits beside the
                    // system-font name it belongs to.
                    .font(.system(size: size * 0.42, weight: .semibold))
                    // Dark ink on a saturated fill, rather than white: at these sizes white on
                    // a mid-tone reads as a smudge.
                    .foregroundStyle(.black.opacity(0.66))
            }
            .overlay {
                // The disc's own edge, drawn as the fill darkened rather than as white
                // lightened. The old stroke was `.white.opacity(0.14)`, which the token file
                // itself lists as a bug — and on white paper a white hairline is nothing at
                // all, so the avatar lost its edge the moment the app learned light mode.
                Circle().stroke(.black.opacity(0.10), lineWidth: DS.Size.hairline)
            }
    }

    private var monogram: String {
        let words = bot.name.split(separator: " ")
        guard let first = words.first?.first else { return "?" }
        if words.count > 1, let second = words.dropFirst().first?.first {
            return String(first).uppercased() + String(second).uppercased()
        }
        return String(first).uppercased()
    }
}
