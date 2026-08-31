import BotHarnessCore
import SwiftUI

/// What the bot is doing right now — and nothing at all when it is doing nothing.
///
/// This replaced a permanent "Activity" bar that sat above the composer whether or not
/// anything was happening. A collapsed chrome bar with a step count is furniture: it claims a
/// row of every conversation for ever to answer a question — "what is it doing?" — that only
/// exists while a run is live. So the answer now exists exactly as long as the question does:
/// while the runner is working, the latest step shimmers here the way ChatGPT and Claude
/// shimmer their status line; the moment the run ends, the line goes with it.
///
/// Nothing is lost by the bar's removal. The full record — every step of every past run, with
/// arguments — is the Activity window, one click on this line or ⇧⌘0 away, and the run's
/// outcome lands in the transcript as a message the way it always did.
struct ThinkingIndicator: View {
    @Environment(BotRunner.self) private var runner
    @Environment(\.openWindow) private var openWindow
    let conversationID: UUID

    private var isRunning: Bool { runner.isRunning(conversationID) }
    private var isAwaiting: Bool { runner.awaiting.values.contains(conversationID) }
    private var latest: String? { runner.live[conversationID]?.last?.text }

    var body: some View {
        Group {
            if isRunning {
                Button { openWindow(id: "activity") } label: {
                    HStack(spacing: DS.Space.md) {
                        if isAwaiting {
                            // Blocked on the user is not "thinking", and it must never wear
                            // the working shimmer — these are the two states this app is not
                            // allowed to blur. Static, in the approval colour, pointing at
                            // the card that is waiting in the transcript.
                            Image(systemName: DS.Status.awaitingApproval.glyph)
                                .font(DS.Text.glyphSmall)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(DS.Status.awaitingApproval.mark)
                                .accessibilityHidden(true)
                            Text("Waiting for you — answer the request above")
                                .font(DS.Text.caption)
                                .foregroundStyle(DS.Status.awaitingApproval.label)
                                .lineLimit(1)
                        } else {
                            ShimmeringText(latest ?? "Thinking…")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: DS.Size.denseRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the full record (⇧⌘0)")
                .accessibilityLabel(isAwaiting ? "Waiting for your approval"
                                               : "Working. \(latest ?? "Thinking")")
                .padding(.bottom, DS.Space.sm)
                .transition(.opacity)
            }
        }
        // Opacity only, so appearing and vanishing survives Reduce Motion as a crossfade.
        .dsAnimation(DS.Motion.instant, value: isRunning, opacityOnly: true)
    }
}
