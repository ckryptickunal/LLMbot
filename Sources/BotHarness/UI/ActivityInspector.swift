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
                }
            }
            .background(DS.Surface.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.Tint.t6, lineWidth: DS.Size.hairline)
            )
            .padding(.horizontal, DS.Space.xxl - 2)
            .padding(.bottom, DS.Space.sm)
            .dsAnimation(DS.Motion.panel, value: expanded)
            .dsAnimation(DS.Motion.instant, value: steps.count)
        }
    }

    // MARK: Header

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "chevron.right")
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(DS.Ink.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))

                if isRunning {
                    Spinner(size: DS.Size.glyph)
                }

                Text(isRunning ? "Working" : "Activity")
                    .font(DS.Text.caption.weight(.medium))
                    .foregroundStyle(isRunning ? DS.Ink.primary : DS.Ink.secondary)

                // Collapsed and running, the latest line is the one thing worth surfacing.
                if let latest = steps.last, !expanded, isRunning {
                    Text("· \(latest.text)")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.Space.sm)

                Text("\(steps.count)")
                    .font(DS.Text.monoSmall)
                    .foregroundStyle(DS.Ink.tertiary)
            }
            .padding(.horizontal, DS.Space.lg - 1)
            .padding(.vertical, DS.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide what it is doing" : "Show what it is doing")
    }

    // MARK: Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.sm - 1) {
                    ForEach(steps) { step in
                        row(step).id(step.id)
                    }
                }
                .padding(.horizontal, DS.Space.lg - 1)
                .padding(.vertical, DS.Space.md + 1)
            }
            .frame(maxHeight: 220)
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
                .frame(width: DS.Space.lg + 1, height: DS.Space.xl - 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.primary)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: DS.Space.xs)

            Text(step.at, format: .dateTime.hour().minute().second())
                .font(DS.Text.monoSmall)
                .foregroundStyle(DS.Ink.tertiary.opacity(0.7))
        }
    }

    private func tint(_ kind: BotRunner.LiveStep.Kind) -> Color {
        switch kind {
        case .thinking:  return DS.Status.waiting.mark
        case .observing: return DS.Ink.tertiary
        case .tool:      return DS.Status.running.mark
        case .result:    return DS.Status.done.mark
        case .verifying: return DS.Status.waiting.mark
        case .approval:  return DS.Status.running.mark
        case .finished:  return DS.Status.done.mark
        case .failed:    return DS.Status.failed.mark
        }
    }
}
