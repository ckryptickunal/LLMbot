import SwiftUI
import BotHarnessCore

/// A live view of what the bot is doing, behind a chevron.
///
/// Collapsed by default and remembered per user, because the answer to "what is it doing" is
/// wanted occasionally and the conversation is wanted always. Expanded, it streams every step
/// as it happens: what the model decided to do and why, what it looked at, what came back.
///
/// One honest limitation, stated in the interface rather than hidden: Gemini does not return
/// readable reasoning. Its `thought` steps carry an opaque signature and nothing else. What
/// can be shown is the model's stated **intent** for each action, which it does return on
/// every tool call, plus everything the harness itself did. That is genuinely most of what
/// "what is it working on" means, and pretending to show more would be inventing text.
struct ActivityInspector: View {
    @Environment(BotRunner.self) private var runner
    let conversationID: UUID

    @AppStorage("activity.expanded") private var expanded = false
    @State private var autoScroll = true

    private var steps: [BotRunner.LiveStep] { runner.live[conversationID] ?? [] }
    private var isRunning: Bool { runner.isRunning(conversationID) }

    var body: some View {
        if !steps.isEmpty || isRunning {
            VStack(spacing: 0) {
                header
                if expanded {
                    Divider().overlay(DS.Colour.line)
                    stream
                }
            }
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(DS.Colour.line, lineWidth: 1)
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
            // Disclosure is an occasional surface, so it earns a real transition — but a fast
            // one. Anything past about 250ms starts to feel like waiting.
            .animation(.easeOut(duration: 0.18), value: expanded)
            .animation(.easeOut(duration: 0.12), value: steps.count)
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Colour.inkTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))

                if isRunning {
                    // A faster spinner reads as a faster app, even at identical speed.
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isRunning ? DS.Colour.ink : DS.Colour.inkSecondary)

                if let latest = steps.last, !expanded, isRunning {
                    Text("· \(latest.text)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Colour.inkTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text("\(steps.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide what it is doing" : "Show what it is doing")
    }

    private var title: String {
        isRunning ? "Working" : "Activity"
    }

    // MARK: Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in
                        row(step).id(step.id)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }
            .frame(maxHeight: 220)
            .onChange(of: steps.count) {
                guard autoScroll, let last = steps.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func row(_ step: BotRunner.LiveStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: step.kind.icon)
                .font(.system(size: 9))
                .foregroundStyle(tint(step.kind))
                .frame(width: 13, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colour.ink)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Colour.inkTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 4)

            Text(step.at, format: .dateTime.hour().minute().second())
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DS.Colour.inkTertiary.opacity(0.7))
        }
    }

    private func tint(_ kind: BotRunner.LiveStep.Kind) -> Color {
        switch kind {
        case .thinking:  return DS.Colour.waiting
        case .observing: return DS.Colour.inkTertiary
        case .tool:      return DS.Colour.running
        case .result:    return DS.Colour.done
        case .verifying: return DS.Colour.waiting
        case .approval:  return DS.Colour.running
        case .finished:  return DS.Colour.done
        case .failed:    return DS.Colour.failed
        }
    }
}
