import AppKit
import BotHarnessCore
import SwiftUI

/// One entry in the timeline.
///
/// Dispatches on the message body so prose, tool activity, screenshots, approvals and system
/// notices all live in one date-ordered list. That is the point: the record of the work and
/// the record of the conversation are the same thing.
struct MessageRow: View {
    let message: Message
    let conversationID: UUID

    var body: some View {
        switch message.body {
        case .text(let text):
            TextBubble(text: text, isUser: message.author == nil,
                       at: message.timestamp, messageID: message.id,
                       conversationID: conversationID)

        case .toolUse(let activity):
            ToolCard(activity: activity)

        case .computer(let activity):
            ComputerCard(activity: activity)

        case .approval(let request):
            ApprovalCard(request: request, messageID: message.id,
                         conversationID: conversationID)

        case .screenshot(let shot):
            ScreenshotCard(shot: shot)

        case .notice(let text):
            Text(text)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Space.sm)

        case .failure(let text):
            FailureRow(text: text, conversationID: conversationID)
        }
    }
}

// MARK: - Prose

private struct TextBubble: View {
    @Environment(Store.self) private var store
    let text: String
    let isUser: Bool
    let at: Date
    let messageID: UUID
    let conversationID: UUID

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.sm) {
            if isUser { Spacer(minLength: DS.Space.xxxl) ; timestamp }
            bubble
            if !isUser { timestamp ; Spacer(minLength: DS.Space.xxxl) }
        }
        .onHover { hovering = $0 }
        .dsAnimation(DS.Motion.instant, value: hovering, opacityOnly: true)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(ProseBlock.parse(text)) { block in
                switch block {
                case .prose(let body):
                    Text(inline(body))
                        .font(DS.Text.body)
                        .foregroundStyle(DS.Ink.primary)
                        .lineSpacing(DS.Text.bodyLineSpacing)
                        .textSelection(.enabled)
                case .code(let language, let body):
                    CodeBlock(language: language, body: body)
                }
            }
        }
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
        .contextMenu {
            Button("Copy Message") { Clipboard.copy(text) }
            Button("Delete Message", role: .destructive) {
                store.deleteMessage(messageID, in: conversationID)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Bot") at \(at.formatted(date: .omitted, time: .shortened)): \(text)")
    }

    /// Revealed on hover rather than always drawn. Every message needs a time available; not
    /// every message needs one competing with the sentence next to it.
    @ViewBuilder private var timestamp: some View {
        Text(at, format: .dateTime.hour().minute())
            .font(DS.Text.micro)
            .foregroundStyle(DS.Ink.secondary)
            .opacity(hovering ? 1 : 0)
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// Inline markdown only, applied per prose block — fenced code never reaches this.
    private func inline(_ body: String) -> AttributedString {
        (try? AttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(body)
    }
}

/// A fenced block: monospaced, scrollable sideways, and copyable in one action.
struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    init(language: String?, body: String) {
        self.language = language
        self.code = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Clipboard.copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(DS.Text.micro)
                        .foregroundStyle(copied ? DS.Status.done.label : DS.Ink.secondary)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Copy code")
            }
            // Long commands scroll inside the block rather than widening the bubble past the
            // reading measure or wrapping mid-token where a line break changes what it means.
            ScrollView(.horizontal) {
                Text(code)
                    .font(DS.Text.mono)
                    .foregroundStyle(DS.Ink.primary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(minWidth: 0, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background(DS.Surface.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .dsAnimation(DS.Motion.instant, value: copied)
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
                        .accessibilityHidden(true)
                    Text(activity.summary)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(expanded ? nil : 2)
                    Spacer(minLength: DS.Space.md)
                    if let duration { 
                        Text(duration)
                            .font(DS.Text.micro)
                            .foregroundStyle(DS.Ink.secondary)
                            .fixedSize()
                    }
                    StatusPill(activity.status.pillState, activity.status.label)
                }

                if activity.status == .interrupted {
                    Text("The app stopped while this was running, so how it ended is unknown. "
                       + "It was not retried.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .onTapGesture { withAnimation(DS.Motion.disclosure) { expanded.toggle() } }
        .contextMenu {
            Button(expanded ? "Collapse" : "Expand") {
                withAnimation(DS.Motion.disclosure) { expanded.toggle() }
            }
            Button("Copy Arguments") { Clipboard.copy(activity.detail) }
            if !activity.output.isEmpty {
                Button("Copy Result") { Clipboard.copy(activity.output) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.summary). \(activity.status.label)")
        .accessibilityHint(expanded ? "Collapse details" : "Expand details")
        .accessibilityAddTraits(.isButton)
    }

    /// How long it took. Present for anything finished, because "why was that slow" is the
    /// second question anyone asks about an agent, and the timestamps were already stored.
    private var duration: String? {
        guard let finished = activity.finishedAt else { return nil }
        let seconds = finished.timeIntervalSince(activity.startedAt)
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm %.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }

    private func detailBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Text.micro)
                .foregroundStyle(DS.Ink.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(DS.Text.mono)
                    .foregroundStyle(DS.Ink.primary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(minWidth: 0, alignment: .leading)
            }
            .scrollIndicators(.automatic)
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
                    Label("Waiting for you — this needs a person.", systemImage: "hand.raised.fill")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Status.awaitingApproval.label)
                } else if activity.status == .interrupted {
                    Text("The app stopped while this was running.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                }

                SecondaryButton("Open computer", systemImage: "display") {
                    ui.openComputer()
                }
            }
        }
        .frame(maxWidth: DS.Window.computerCardMax, alignment: .leading)
        .contextMenu { Button("Copy Task") { Clipboard.copy(activity.task) } }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Approval

/// A permission prompt, shown in the timeline rather than as a modal.
///
/// Modals are wrong here twice over: the record of what was approved belongs beside the work
/// it approved, and a bot running unattended hits approvals when nobody is looking — a modal
/// blocking the window would make every other conversation unusable.
private struct ApprovalCard: View {
    @Environment(BotRunner.self) private var runner
    let request: ApprovalRequest
    let messageID: UUID
    let conversationID: UUID

    var body: some View {
        Surface(borderTint: borderTint) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: request.answer == nil ? "hand.raised.fill" : "checkmark.seal")
                        .font(DS.Text.glyphSmall)
                        .foregroundStyle(request.answer == nil
                                         ? DS.Status.awaitingApproval.mark : DS.Ink.secondary)
                        .accessibilityHidden(true)
                    Text(request.answer == nil ? "Needs your approval" : "Approval")
                        .font(DS.Text.callout.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                    Spacer()
                }

                Text(request.summary)
                    .font(DS.Text.body)
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Users approve what they can see. A summary alone is not consent, and an
                // elided confirmation dialog is a disclosed vulnerability in a comparable tool.
                CodeBlock(language: nil, body: request.detail)

                Text(request.reason)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let answer = request.answer {
                    Label(label(for: answer), systemImage: glyph(for: answer))
                        .font(DS.Text.callout.weight(.medium))
                        .foregroundStyle(tint(for: answer))
                } else {
                    // Four answers, not three. "Never allow this" is as much an answer as
                    // "always allow this", and a permission system that can only be loosened
                    // is not one.
                    HStack(spacing: DS.Space.md) {
                        PrimaryButton("Allow once") { answer(.allowedOnce) }
                        SecondaryButton("Always allow") { answer(.allowedAlways) }
                        Spacer(minLength: DS.Space.sm)
                        SecondaryButton("Deny", role: .destructive) { answer(.denied) }
                        SecondaryButton("Never", role: .destructive) { answer(.deniedAlways) }
                    }
                }
            }
        }
        .frame(maxWidth: DS.Size.cardMax, alignment: .leading)
        .contextMenu { Button("Copy Command") { Clipboard.copy(request.detail) } }
        .accessibilityElement(children: .contain)
    }

    private var borderTint: Color {
        request.answer == nil ? DS.Status.awaitingApproval.mark.opacity(0.4) : DS.Tint.t6
    }

    private func answer(_ a: ApprovalRequest.Answer) {
        runner.answer(a, for: messageID, in: conversationID)
    }

    private func tint(for answer: ApprovalRequest.Answer) -> Color {
        switch answer {
        case .allowedOnce, .allowedAlways: return DS.Status.done.label
        case .denied, .deniedAlways:       return DS.Status.failed.label
        case .expired:                     return DS.Ink.secondary
        }
    }

    private func glyph(for answer: ApprovalRequest.Answer) -> String {
        switch answer {
        case .allowedOnce, .allowedAlways: return "checkmark.circle.fill"
        case .denied, .deniedAlways:       return "nosign"
        case .expired:                     return "clock.badge.xmark"
        }
    }

    private func label(for answer: ApprovalRequest.Answer) -> String {
        switch answer {
        case .allowedOnce:   return "You allowed this once"
        case .allowedAlways: return "You allowed this, and added a rule"
        case .denied:        return "You denied this"
        case .deniedAlways:  return "You denied this, and added a rule"
        case .expired:       return "This expired when the run ended — it was never done"
        }
    }
}

// MARK: - Failure

/// Something went wrong, with the one thing the user actually wants next.
private struct FailureRow: View {
    @Environment(BotRunner.self) private var runner
    let text: String
    let conversationID: UUID

    var body: some View {
        ErrorState(text, retry: retry)
            .frame(maxWidth: DS.Size.cardMax, alignment: .leading)
            .contextMenu { Button("Copy Error") { Clipboard.copy(text) } }
    }

    /// Re-send what the user asked for, rather than making them retype it.
    ///
    /// Nil when there is nothing to retry or a run already owns the conversation, so the
    /// button is absent instead of present-and-inert.
    private var retry: (() -> Void)? {
        guard runner.canSend(in: conversationID),
              let request = runner.lastUserRequest(in: conversationID)
        else { return nil }
        return { runner.send(request, in: conversationID) }
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
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Screenshot: \(shot.caption). Open full size.")
                } else if failed {
                    // The artifact was cleaned up or moved. Say so rather than showing a void.
                    Surface(fill: DS.Tint.t3, bordered: false) {
                        Text("That screenshot is no longer on disk.")
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                } else {
                    // Sized from the image's own aspect where it is known, so nothing jumps
                    // when it lands. A fixed box was only ever right for one shape of screen.
                    Skeleton(height: DS.Size.screenshotMax * 0.62, radius: DS.Radius.md)
                }
            }
            .frame(minWidth: DS.Size.screenshotMin, maxWidth: DS.Size.screenshotMax)

            Text(shot.caption)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
        }
        .task(id: shot.path) { await load() }
        .contextMenu {
            Button("Open Full Size") { zoomed = true }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shot.path)])
            }
            Button("Copy Caption") { Clipboard.copy(shot.caption) }
        }
        .sheet(isPresented: $zoomed) { zoomedView }
    }

    @ViewBuilder private var zoomedView: some View {
        if let image {
            VStack(spacing: 0) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                HStack(spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(shot.caption)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.primary)
                        Text(shot.takenAt, format: .dateTime.hour().minute().second())
                            .font(DS.Text.micro)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                    Spacer()
                    SecondaryButton("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: shot.path)])
                    }
                    // Escape closes it too — a sheet whose only exit is one button is a sheet
                    // people feel trapped in.
                    SecondaryButton("Done") { zoomed = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(DS.Space.lg)
            }
            .frame(minWidth: DS.Window.viewerMinWidth, minHeight: DS.Window.viewerMinHeight)
            .background(DS.Surface.ground)
        }
    }

    /// Decoding runs off the main actor: a Retina PNG is several megabytes, and decoding it on
    /// the main thread drops frames in the message list while a run is streaming.
    ///
    /// Cached by path, because a lazy list re-materialises rows constantly and re-reading a
    /// multi-megabyte file on every scroll pass is a hitch you can feel.
    private func load() async {
        let path = shot.path
        if let cached = ImageCache.shared.image(for: path) { image = cached; return }
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return NSImage(data: data)
        }.value
        await MainActor.run {
            if let loaded {
                ImageCache.shared.store(loaded, for: path)
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// One decoded copy of each screenshot, bounded so a long transcript cannot grow without limit.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 40 }

    func image(for path: String) -> NSImage? { cache.object(forKey: path as NSString) }
    func store(_ image: NSImage, for path: String) { cache.setObject(image, forKey: path as NSString) }
}

// MARK: - Clipboard

/// One place that writes to the pasteboard, so every copy action behaves identically.
enum Clipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
