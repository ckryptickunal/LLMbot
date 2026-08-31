import BotHarnessCore
import SwiftUI

/// A live view of what the bot is doing, behind a chevron.
///
/// Collapsed by default and remembered, because "what is it doing" is wanted occasionally and
/// the conversation is wanted always. Expanded, it streams every step as it happens.
///
/// One honest limitation, stated in the interface rather than hidden: Gemini returns no
/// readable reasoning — its `thought` steps carry an opaque signature and nothing else. What
/// can be shown is the model's stated **intent** for each action, which it does return on every
/// tool call, plus everything the harness itself did. That is most of what "what is it working
/// on" means, and inventing the rest would be inventing text.
struct ActivityInspector: View {
    @Environment(BotRunner.self) private var runner
    @Environment(\.openWindow) private var openWindow
    let conversationID: UUID

    @AppStorage("activity.expanded") private var expanded = false

    private var steps: [BotRunner.LiveStep] { runner.live[conversationID] ?? [] }
    private var isRunning: Bool { runner.isRunning(conversationID) }

    var body: some View {
        if !steps.isEmpty || isRunning {
            VStack(spacing: 0) {
                header
                if expanded {
                    Hairline()
                    stream
                    Hairline()
                    // This stream is a peek at the current run; the Activity window is the
                    // whole record, with every past run and every argument. Nothing connected
                    // the two, and the window was reachable only from a popover in the roster.
                    Button { openWindow(id: "activity") } label: {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(DS.Text.glyphSmall)
                                .accessibilityHidden(true)
                            Text("Open the full record (⇧⌘0)")
                                .font(DS.Text.caption)
                            Spacer()
                        }
                        .foregroundStyle(DS.Ink.secondary)
                        .padding(.horizontal, DS.Space.lg)
                        .frame(minHeight: DS.Size.hit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
            }
            .background(DS.Surface.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.Tint.t6, lineWidth: DS.Size.hairline)
            )
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.sm)
            .dsAnimation(DS.Motion.panel, value: expanded)
            .motion(DS.Motion.rowInsert, value: steps.count)
        }
    }

    // MARK: Header

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "chevron.right")
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(DS.Ink.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)

                if isRunning {
                    DelayedSpinner(size: DS.Size.glyph)
                }

                Text(isRunning ? "Working" : "Activity")
                    .font(DS.Text.caption.weight(.medium))
                    .foregroundStyle(isRunning ? DS.Ink.primary : DS.Ink.secondary)

                // Collapsed and running, the latest line is the one thing worth surfacing.
                if let latest = steps.last, !expanded, isRunning {
                    Text("· \(latest.text)")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.Space.sm)

                Text("\(steps.count)")
                    .font(DS.Text.monoSmall)
                    .foregroundStyle(DS.Ink.secondary)
            }
            .padding(.horizontal, DS.Space.lg)
            .frame(minHeight: DS.Size.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide what it is doing" : "Show what it is doing")
        .accessibilityLabel(isRunning ? "Working. \(steps.count) steps" : "Activity. \(steps.count) steps")
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }

    // MARK: Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(steps) { step in
                        row(step).id(step.id)
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
            }
            .frame(maxHeight: DS.Size.activityStreamMax)  // cap: a peek, not a second transcript
            .onChange(of: steps.count) {
                guard let last = steps.last else { return }
                withAnimation(DS.Motion.instant) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func row(_ step: BotRunner.LiveStep) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: step.kind.icon)
                .font(DS.Text.glyphSmall)
                .foregroundStyle(tint(step.kind))
                .frame(width: DS.Space.lg, height: DS.Space.lg)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.primary)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: DS.Space.xs)

            Text(step.at, format: .dateTime.hour().minute().second())
                .font(DS.Text.monoSmall)
                .foregroundStyle(DS.Ink.secondary)
        }
    }

    private func tint(_ kind: BotRunner.LiveStep.Kind) -> Color {
        switch kind {
        case .thinking:  return DS.Status.waiting.mark
        case .observing: return DS.Ink.secondary
        case .tool:      return DS.Status.running.mark
        case .result:    return DS.Status.done.mark
        case .verifying: return DS.Status.waiting.mark
        // The one colour rule with a real cost if broken, stated in the tokens: `running` and
        // `awaitingApproval` must never share a colour. "Working" and "blocked on you" are the
        // two states in this app that must not be confused, and this row was painting the
        // second in the first's exact amber.
        case .approval:  return DS.Status.awaitingApproval.mark
        case .finished:  return DS.Status.done.mark
        case .failed:    return DS.Status.failed.mark
        }
    }
}
