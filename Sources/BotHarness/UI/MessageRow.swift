import BotHarnessCore
import SwiftUI

/// One entry in the timeline. Dispatches on the message body so that prose, tool activity,
/// computer activity, approvals and notices all live in one date-ordered list.
struct MessageRow: View {
    @Environment(Store.self) private var store
    let message: Message

    var body: some View {
        switch message.body {
        case .text(let text):
            TextBubble(text: text, isUser: message.author == nil)

        case .toolUse(let activity):
            ToolCard(activity: activity)

        case .computer(let activity):
            ComputerCard(activity: activity)

        case .approval(let request):
            ApprovalCard(request: request, messageID: message.id)

        case .notice(let text):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)

        case .failure(let text):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failed)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primary)
            }
            .padding(11)
            .background(Theme.failed.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }
}

private struct TextBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            Text(attributed)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    (isUser ? Theme.bubbleUser : Theme.bubbleBot),
                    in: RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                )
                .frame(maxWidth: 620, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 60) }
        }
    }

    /// Markdown is parsed for inline emphasis and code. Full block markdown (lists, tables)
    /// is deliberately deferred: bots here are instructed to write prose, and rendering a
    /// full markdown engine before that is a problem would be building for a bot we have
    /// asked not to exist.
    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A tool call, collapsed to one line until you want the detail.
private struct ToolCard: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Text(activity.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primary)
                Spacer()
                StatusPill(status: activity.status)
            }
            if expanded {
                Text(activity.detail.isEmpty ? "(no arguments)" : activity.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                if !activity.output.isEmpty {
                    Text(activity.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.separator, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.routine) { expanded.toggle() } }
    }

    private var icon: String {
        switch activity.tool {
        case let t where t.hasPrefix("shell"):   return "terminal"
        case let t where t.hasPrefix("files"):   return "doc.text"
        case let t where t.hasPrefix("browser"): return "globe"
        case let t where t.hasPrefix("git"):     return "arrow.triangle.branch"
        default:                                  return "wrench.and.screwdriver"
        }
    }
}

/// The Computer card.
///
/// Grok Bot's best interface idea, and the one worth copying most exactly: a single element
/// that is at once the progress indicator, the plain-language explanation of what the machine
/// is being asked to do, and the door through which the human takes over.
private struct ComputerCard: View {
    @Environment(UIState.self) private var ui
    let activity: ComputerActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Computer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                StatusPill(status: activity.status)
            }

            Text(activity.task)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if activity.awaitingHuman {
                Text("Waiting for you — this needs a person.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.waiting)
            }

            Button {
                ui.openComputer()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "display")
                        .font(.system(size: 11))
                    Text("Open computer")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: 400, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }
}

/// A permission prompt, shown in the timeline rather than as a modal.
///
/// Modals are wrong here for two reasons: the record of what was approved belongs beside the
/// work it approved, and a bot running unattended will hit approvals when nobody is looking —
/// a modal blocking the whole window would make every other conversation unusable.
private struct ApprovalCard: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    let request: ApprovalRequest
    let messageID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.waiting)
                Text("Needs your approval")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
            }

            Text(request.summary)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)

            // Users approve what they can see. The summary alone is not consent.
            Text(request.detail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            Text(request.reason)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)

            if let answer = request.answer {
                Text(label(for: answer))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(answer == .denied || answer == .deniedAlways ? Theme.failed : Theme.done)
            } else {
                HStack(spacing: 8) {
                    approvalButton("Allow once", tint: Theme.done) { answer(.allowedOnce) }
                    approvalButton("Always allow this", tint: Theme.done.opacity(0.7)) { answer(.allowedAlways) }
                    approvalButton("Deny", tint: Theme.failed) { answer(.denied) }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.waiting.opacity(0.35), lineWidth: 1)
        )
    }

    private func answer(_ a: ApprovalRequest.Answer) {
        guard let conversation = store.selection else { return }
        runner.answer(a, for: messageID, in: conversation)
    }

    private func approvalButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func label(for answer: ApprovalRequest.Answer) -> String {
        switch answer {
        case .allowedOnce:   return "You allowed this once"
        case .allowedAlways: return "You allowed this, and added a rule"
        case .denied:        return "You denied this"
        case .deniedAlways:  return "You denied this, and added a rule"
        }
    }
}

struct StatusPill: View {
    let status: ToolActivity.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    private var colour: Color {
        switch status {
        case .running:            return Theme.running
        case .done:               return Theme.done
        case .failed:             return Theme.failed
        case .refused:            return Theme.failed
        case .waitingForApproval: return Theme.waiting
        }
    }

    private var label: String {
        switch status {
        case .running:            return "Running"
        case .done:               return "Done"
        case .failed:             return "Failed"
        case .refused:            return "Refused"
        case .waitingForApproval: return "Needs approval"
        }
    }
}
