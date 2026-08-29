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
                .foregroundStyle(DS.Colour.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)

        case .screenshot(let shot):
            ScreenshotCard(shot: shot)

        case .failure(let text):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colour.failed)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.ink)
            }
            .padding(11)
            .background(DS.Colour.failed.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.lg))
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
                .foregroundStyle(DS.Colour.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    (isUser ? DS.Colour.bubbleUser : DS.Colour.bubbleBot),
                    in: RoundedRectangle(cornerRadius: DS.Radius.xl)
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
                    .foregroundStyle(DS.Colour.inkSecondary)
                Text(activity.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.ink)
                Spacer()
                StatusPill(activity.status.pillState, activity.status.label)
            }
            if expanded {
                Text(activity.detail.isEmpty ? "(no arguments)" : activity.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .textSelection(.enabled)
                if !activity.output.isEmpty {
                    Text(activity.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DS.Colour.inkTertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: 620, alignment: .leading)
        .background(DS.Colour.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.Colour.line, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.instant) { expanded.toggle() } }
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
                    .foregroundStyle(DS.Colour.ink)
                Spacer()
                StatusPill(activity.status.pillState, activity.status.label)
            }

            Text(activity.task)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colour.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if activity.awaitingHuman {
                Text("Waiting for you — this needs a person.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colour.waiting)
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
                .foregroundStyle(DS.Colour.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(12)
        .frame(maxWidth: 400, alignment: .leading)
        .background(DS.Colour.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.Colour.line, lineWidth: 1)
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
                    .foregroundStyle(DS.Colour.waiting)
                Text("Needs your approval")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colour.ink)
                Spacer()
            }

            Text(request.summary)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colour.ink)

            // Users approve what they can see. The summary alone is not consent.
            Text(request.detail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DS.Colour.inkSecondary)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            Text(request.reason)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colour.inkTertiary)

            if let answer = request.answer {
                Text(label(for: answer))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(answer == .denied || answer == .deniedAlways ? DS.Colour.failed : DS.Colour.done)
            } else {
                HStack(spacing: 8) {
                    approvalButton("Allow once", tint: DS.Colour.done) { answer(.allowedOnce) }
                    approvalButton("Always allow this", tint: DS.Colour.done.opacity(0.7)) { answer(.allowedAlways) }
                    approvalButton("Deny", tint: DS.Colour.failed) { answer(.denied) }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: 620, alignment: .leading)
        .background(DS.Colour.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.Colour.waiting.opacity(0.35), lineWidth: 1)
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

/// What the bot saw.
///
/// The single most reassuring element in the product: watching an agent work is far easier to
/// trust than reading its account of having worked. Grok Bot posts these inline after each
/// action and it is the right call.
///
/// The image is loaded from disk on demand and never held in the conversation document, so a
/// long run does not bloat the file that gets rewritten on every message.
struct ScreenshotCard: View {
    let shot: Screenshot
    @State private var image: NSImage?
    @State private var failed = false
    @State private var zoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.md)
                                .stroke(DS.Colour.line, lineWidth: DS.Size.hairline)
                        )
                        .onTapGesture { zoomed = true }
                        .help("Click to see it full size")
                } else if failed {
                    // The artifact was cleaned up or moved. Say so rather than showing a void.
                    Surface(fill: DS.Colour.fill, bordered: false) {
                        Text("That screenshot is no longer on disk.")
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Colour.inkTertiary)
                    }
                } else {
                    // Sized like the image it is standing in for, so nothing jumps when it lands.
                    Skeleton(height: 220, radius: DS.Radius.md)
                }
            }
            .frame(maxWidth: 460)

            Text(shot.caption)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Colour.inkTertiary)
        }
        .task(id: shot.path) { await load() }
        .sheet(isPresented: $zoomed) {
            if let image {
                VStack(spacing: 0) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    HStack {
                        Text(shot.caption).font(DS.Text.caption)
                            .foregroundStyle(DS.Colour.inkSecondary)
                        Spacer()
                        SecondaryButton("Done") { zoomed = false }
                    }
                    .padding(DS.Space.lg)
                }
                .frame(minWidth: 720, minHeight: 480)
                .background(DS.Colour.ground)
            }
        }
    }

    /// Decoding happens off the main actor: a Retina PNG is several megabytes and decoding it
    /// on the main thread drops frames in the message list while a run is streaming.
    private func load() async {
        let path = shot.path
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return NSImage(data: data)
        }.value
        await MainActor.run {
            if let loaded { image = loaded } else { failed = true }
        }
    }
}
