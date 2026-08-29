import SwiftUI
import BotHarnessCore

/// The activity inspector: every run, every step, and what actually happened.
///
/// This is the answer to "figure out what went wrong and fix it". Traces have been written to
/// disk since the first commit, but a trace nobody can read is bookkeeping rather than
/// observability — the whole value is in opening a run that failed and seeing the step where
/// it turned.
///
/// What each row can tell you, when it is there: the model's stated intent for the step, the
/// literal arguments, what came back, what the permission system decided and which layer
/// decided it, and tokens and cost. Plus whether the record is intact, since a hash-chained
/// log that is never checked is just a log.
struct ActivityWindow: View {
    @State private var reader = TraceReader()
    @State private var runs: [TraceReader.Run] = []
    @State private var selected: TraceReader.Run?
    @State private var timeline: [TraceReader.Entry] = []

    var body: some View {
        HSplitView {
            runList.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail.frame(minWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(Theme.ground)
        .onAppear(perform: reload)
    }

    private func reload() {
        runs = reader.runs()
        if selected == nil { select(runs.first) }
    }

    private func select(_ run: TraceReader.Run?) {
        selected = run
        timeline = run.map { reader.timeline(in: $0.directory) } ?? []
    }

    // MARK: Runs

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Runs").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().overlay(Theme.separator)

            if runs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18)).foregroundStyle(Theme.tertiary)
                    Text("No runs yet").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text("Every task a bot runs is recorded here.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(runs) { run in
                        runRow(run)
                            .background(selected?.id == run.id ? Color.white.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture { select(run) }
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.panel)
    }

    private func runRow(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(colour(for: run)).frame(width: 6, height: 6)
                Text(run.manifest?.goal ?? run.id)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(run.startedAt, style: .relative)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                Text("\(run.stepCount) steps")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                if let cost = run.manifest?.totalCostUSD, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
            }
            if let failure = run.failureSummary {
                Text(failure).font(.system(size: 10.5)).foregroundStyle(Theme.failed).lineLimit(1)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colour(for run: TraceReader.Run) -> Color {
        switch run.manifest?.outcome {
        case .succeeded: return Theme.done
        case .failed, .timedOut: return Theme.failed
        case .refused: return Theme.running
        case .cancelled: return Theme.tertiary
        case .none: return run.failureSummary == nil ? Theme.tertiary : Theme.failed
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let run = selected {
            VStack(spacing: 0) {
                header(run)
                Divider().overlay(Theme.separator)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(timeline) { entry in StepRow(entry: entry) }
                    }
                    .padding(14)
                }
            }
        } else {
            Text("Select a run").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.manifest?.goal ?? run.id)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.primary)
            HStack(spacing: 12) {
                if let m = run.manifest {
                    label("bot", m.botName)
                    label("brain", m.brain)
                    label("tokens", "\(m.totalPromptTokens + m.totalCompletionTokens)")
                    if m.totalCostUSD > 0 { label("cost", String(format: "$%.4f", m.totalCostUSD)) }
                }
                chainBadge(run.chain)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([run.directory])
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 11))
            }
            if let note = run.manifest?.closingNote, !note.isEmpty {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func label(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
        }
    }

    /// A hash chain nobody checks is decoration. This checks it, every time a run is opened.
    @ViewBuilder private func chainBadge(_ status: TraceWriter.ChainStatus) -> some View {
        switch status {
        case .intact(let records):
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 8))
                Text("\(records) records intact").font(.system(size: 10))
            }
            .foregroundStyle(Theme.done)
        case .brokenAt(let line, let reason):
            HStack(spacing: 4) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark").font(.system(size: 8))
                Text("altered at line \(line) — \(reason)").font(.system(size: 10))
            }
            .foregroundStyle(Theme.failed)
        case .unreadable:
            Text("record unreadable").font(.system(size: 10)).foregroundStyle(Theme.failed)
        }
    }
}

// MARK: - One step

private struct StepRow: View {
    let entry: TraceReader.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(entry.seq)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, alignment: .trailing)

                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(expanded ? nil : 2)

                    // The model's stated reason for this step — the "decision" in decision trace.
                    if let intent = entry.intent, intent != entry.summary {
                        Text(intent).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }

                    if let permission = entry.permission {
                        HStack(spacing: 5) {
                            Image(systemName: permission.outcome == "allowed" ? "checkmark.shield"
                                  : permission.outcome == "asked" ? "hand.raised" : "nosign")
                                .font(.system(size: 9))
                            Text("\(permission.outcome) — \(permission.reason)")
                                .font(.system(size: 10.5))
                        }
                        .foregroundStyle(permission.outcome == "refused" ? Theme.failed : Theme.tertiary)
                    }

                    if let error = entry.error, !error.isEmpty {
                        Text(error).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.failed)
                            .lineLimit(expanded ? nil : 2)
                    }
                }
                Spacer(minLength: 6)

                if entry.tokens > 0 {
                    Text("\(entry.tokens) tok")
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
                Text(entry.at, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }

            if expanded {
                if let arguments = entry.arguments, !arguments.isEmpty {
                    block("arguments", arguments)
                }
                if let output = entry.output, !output.isEmpty {
                    block("result", output)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.routine) { expanded.toggle() } }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.leading, 44)
    }

    private var icon: String {
        switch entry.kind {
        case .runStarted:      return "play.circle"
        case .runFinished:     return "flag.checkered"
        case .modelCall,
             .modelResponse:   return "brain"
        case .toolProposed:    return "wrench.and.screwdriver"
        case .permissionCheck: return "hand.raised"
        case .verification:    return "checkmark.seal"
        case .stuckDetected:   return "exclamationmark.triangle"
        case .recovery:        return "arrow.uturn.backward"
        case .screenshot:      return "camera"
        case .userMessage:     return "person"
        default:               return "circle"
        }
    }

    private var tint: Color {
        if entry.error != nil { return Theme.failed }
        if entry.permission?.outcome == "refused" { return Theme.failed }
        if entry.kind == .stuckDetected { return Theme.running }
        if entry.outcome == .succeeded { return Theme.done }
        return Theme.tertiary
    }
}
