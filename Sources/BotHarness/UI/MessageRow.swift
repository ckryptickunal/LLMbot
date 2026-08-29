import BotHarnessCore
import SwiftUI

/// One entry in the timeline.
///
/// Dispatches on the message body so prose, tool activity, screenshots, approvals and system
/// notices all live in one date-ordered list. That is the point: the record of the work and
/// the record of the conversation are the same thing.
struct MessageRow: View {
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

        case .screenshot(let shot):
            ScreenshotCard(shot: shot)

        case .notice(let text):
            Text(text)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Space.sm)

        case .failure(let text):
            ErrorState(text)
                .frame(maxWidth: DS.Size.cardMax, alignment: .leading)
        }
    }
}

// MARK: - Prose

private struct TextBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: DS.Space.xxxl + DS.Space.xl) }
            Text(attributed)
                .font(DS.Text.body)
                .foregroundStyle(DS.Ink.primary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .textSelection(.enabled)
                .dsInset(DS.Inset.bubble)
                .background(isUser ? DS.Surface.active : DS.Surface.raised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.xl))
                // Hugs its content up to the measure. A bubble stretched to the column edge
                // stops reading as a spoken turn and starts reading as a paragraph of layout.
                // A floor as well as a ceiling: below the minimum a bubble wraps to one word
                // a line, which reads as broken rather than tight.
                .frame(minWidth: DS.Size.bubbleMin,
                       maxWidth: DS.Size.bubbleMax,
                       alignment: isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: DS.Space.xxxl + DS.Space.xl) }
        }
    }

    /// Inline markdown only. Bots here are instructed to write prose, so rendering a full
    /// block engine before that is a problem would be building for a bot we asked not to exist.
    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Tool activity

/// A tool call, collapsed to one line until you want the detail.
private struct ToolCard: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        Surface(padding: DS.Inset.card.top) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: icon)
                        .font(DS.Text.glyphSmall)
                        .foregroundStyle(DS.Ink.secondary)
                    Text(activity.summary)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(expanded ? nil : 2)
                    Spacer(minLength: DS.Space.md)
                    StatusPill(activity.status.pillState, activity.status.label)
                }

                if expanded {
                    detailBlock("arguments", activity.detail.isEmpty ? "(none)" : activity.detail)
                    if !activity.output.isEmpty {
                        detailBlock("result", activity.output)
                    }
                }
            }
        }
        .frame(maxWidth: DS.Size.cardMax, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.panel) { expanded.toggle() } }
    }

    private func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Text.micro)
                .foregroundStyle(DS.Ink.tertiary)
            Text(text)
                .font(DS.Text.mono)
                .foregroundStyle(DS.Ink.secondary)
                .textSelection(.enabled)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Surface.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }

    private var icon: String {
        switch activity.tool {
        case let t where t.hasPrefix("shell"):      return "terminal"
        case let t where t.hasPrefix("files"):      return "doc.text"
        case let t where t.hasPrefix("browser"):    return "globe"
        case let t where t.hasPrefix("git"):        return "arrow.triangle.branch"
        case let t where t.hasPrefix("computer"):   return "display"
        case let t where t.hasPrefix("capability"): return "puzzlepiece.extension"
        case let t where t.hasPrefix("memory"):     return "brain"
        default:                                     return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Computer

/// The Computer card.
///
/// Grok Bot's best interface idea, and worth copying exactly: one element that is at once the
/// progress indicator, the plain-language explanation of what the machine was asked to do, and
/// the door through which a human takes over.
private struct ComputerCard: View {
    @Environment(UIState.self) private var ui
    let activity: ComputerActivity

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack {
                    Text("Computer")
                        .font(DS.Text.callout.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                    Spacer()
                    StatusPill(activity.status.pillState, activity.status.label)
                }

                Text(activity.task)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                if activity.awaitingHuman {
                    Text("Waiting for you — this needs a person.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Status.waiting.mark)
                }

                SecondaryButton("Open computer", systemImage: "display") {
                    ui.openComputer()
                }
            }
        }
        .frame(maxWidth: DS.Window.computerCardMax, alignment: .leading)
    }
}

// MARK: - Approval

/// A permission prompt, shown in the timeline rather than as a modal.
///
/// Modals are wrong here twice over: the record of what was approved belongs beside the work
/// it approved, and a bot running unattended hits approvals when nobody is looking — a modal
/// blocking the window would make every other conversation unusable.
private struct ApprovalCard: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    let request: ApprovalRequest
    let messageID: UUID

    var body: some View {
        Surface(borderTint: DS.Status.waiting.mark.opacity(0.35)) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "hand.raised.fill")
                        .font(DS.Text.glyphSmall)
                        .foregroundStyle(DS.Status.waiting.mark)
                    Text("Needs your approval")
                        .font(DS.Text.callout.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                    Spacer()
                }

                Text(request.summary)
                    .font(DS.Text.body)
                    .foregroundStyle(DS.Ink.primary)

                // Users approve what they can see. A summary alone is not consent, and an
                // elided confirmation dialog is a disclosed vulnerability in a comparable tool.
                Text(request.detail)
                    .font(DS.Text.mono)
                    .foregroundStyle(DS.Ink.secondary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Surface.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))

                Text(request.reason)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.tertiary)

                if let answer = request.answer {
                    Text(label(for: answer))
                        .font(DS.Text.callout.weight(.medium))
                        .foregroundStyle(answered(answer) ? DS.Status.done.mark : DS.Status.failed.mark)
                } else {
                    HStack(spacing: DS.Space.md) {
                        SecondaryButton("Allow once") { answer(.allowedOnce) }
                        SecondaryButton("Always allow this") { answer(.allowedAlways) }
                        SecondaryButton("Deny", role: .destructive) { answer(.denied) }
                    }
                }
            }
        }
        .frame(maxWidth: DS.Size.cardMax, alignment: .leading)
    }

    private func answered(_ a: ApprovalRequest.Answer) -> Bool {
        a == .allowedOnce || a == .allowedAlways
    }

    private func answer(_ a: ApprovalRequest.Answer) {
        guard let conversation = store.selection else { return }
        runner.answer(a, for: messageID, in: conversation)
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

// MARK: - Screenshot

/// What the bot saw.
///
/// The most reassuring element in the product: watching an agent work is far easier to trust
/// than reading its account of having worked.
///
/// The image is loaded from disk on demand and never held in the conversation document, so a
/// long run does not bloat the file that is rewritten on every message.
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
                                .stroke(DS.Tint.t6, lineWidth: DS.Size.hairline)
                        )
                        .onTapGesture { zoomed = true }
                        .help("Click to see it full size")
                } else if failed {
                    // The artifact was cleaned up or moved. Say so rather than showing a void.
                    Surface(fill: DS.Tint.t3, bordered: false) {
                        Text("That screenshot is no longer on disk.")
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.tertiary)
                    }
                } else {
                    // Sized like the image it stands in for, so nothing jumps when it lands.
                    Skeleton(height: DS.Size.activityStreamMax, radius: DS.Radius.md)
                }
            }
            .frame(minWidth: DS.Size.screenshotMin, maxWidth: DS.Size.screenshotMax)

            Text(shot.caption)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.tertiary)
        }
        .task(id: shot.path) { await load() }
        .sheet(isPresented: $zoomed) { zoomedView }
    }

    @ViewBuilder private var zoomedView: some View {
        if let image {
            VStack(spacing: 0) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                HStack {
                    Text(shot.caption)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                    Spacer()
                    SecondaryButton("Done") { zoomed = false }
                }
                .padding(DS.Space.lg)
            }
            .frame(minWidth: DS.Window.viewerMinWidth, minHeight: DS.Window.viewerMinHeight)
            .background(DS.Surface.ground)
        }
    }

    /// Decoding runs off the main actor: a Retina PNG is several megabytes, and decoding it on
    /// the main thread drops frames in the message list while a run is streaming.
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
