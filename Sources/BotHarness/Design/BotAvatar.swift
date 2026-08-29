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
            .fill(bot.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(monogram)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    // Dark ink on a saturated fill, rather than white: at these sizes white on
                    // a mid-tone reads as a smudge.
                    .foregroundStyle(.black.opacity(0.62))
            }
            .overlay {
                // A hairline of the fill lightened, so the disc has an edge against the panel
                // without a border that reads as a stroke.
                Circle().stroke(.white.opacity(0.14), lineWidth: DS.Size.hairline)
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
