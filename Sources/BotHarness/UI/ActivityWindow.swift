import BotHarnessCore
import SwiftUI

/// The activity inspector: every run, every step, and what actually happened.
///
/// This is the answer to "figure out what went wrong and fix it". Traces have been written to
/// disk since the first commit, but a trace nobody can read is bookkeeping rather than
/// observability — the value is in opening a run that failed and seeing the step where it
/// turned.
struct ActivityWindow: View {
    @State private var reader = TraceReader()
    @State private var runs: [TraceReader.Run] = []
    @State private var selected: TraceReader.Run?
    @State private var timeline: [TraceReader.Entry] = []
    @State private var loading = true

    var body: some View {
        HSplitView {
            runList.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail.frame(minWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(DS.Colour.ground)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        // Reading a directory of runs touches the disk; keeping it off the main actor means
        // the window paints its skeleton immediately rather than after the scan.
        let found = await Task.detached(priority: .userInitiated) { [reader] in reader.runs() }.value
        runs = found
        loading = false
        if selected == nil { await select(found.first) }
    }

    private func select(_ run: TraceReader.Run?) async {
        selected = run
        guard let run else { timeline = []; return }
        timeline = await Task.detached(priority: .userInitiated) { [reader] in
            reader.timeline(in: run.directory)
        }.value
    }

    // MARK: Runs

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Runs").font(DS.Text.secondary.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                Spacer()
                IconButton("arrow.clockwise", filled: false, help: "Reload") {
                    Task { await reload() }
                }
            }
            .padding(.horizontal, DS.Space.lg + 2)
            .padding(.vertical, DS.Space.lg - 2)

            Hairline()

            if loading {
                VStack(spacing: DS.Space.md) {
                    ForEach(0..<5, id: \.self) { _ in Skeleton(height: 44, radius: DS.Radius.md) }
                }
                .padding(DS.Space.md)
                Spacer()
            } else if runs.isEmpty {
                EmptyState(systemImage: "clock.arrow.circlepath",
                           title: "No runs yet",
                           message: "Every task a bot runs is recorded here.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.hair) {
                        ForEach(runs) { run in
                            runRow(run)
                                .background(selected?.id == run.id ? DS.Colour.fillSelected : .clear,
                                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await select(run) } }
                        }
                    }
                    .padding(DS.Space.md)
                }
            }
        }
        .background(DS.Colour.panel)
    }

    private func runRow(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs - 1) {
            HStack(spacing: DS.Space.sm) {
                Circle().fill(colour(for: run))
                    .frame(width: DS.Size.statusDot - 0.5, height: DS.Size.statusDot - 0.5)
                Text(run.manifest?.goal ?? run.id)
                    .font(DS.Text.secondary.weight(.medium))
                    .foregroundStyle(DS.Colour.ink)
                    .lineLimit(1)
            }
            HStack(spacing: DS.Space.md) {
                Text(run.startedAt, style: .relative)
                    .font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                Text("\(run.stepCount) steps")
                    .font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                if let cost = run.manifest?.totalCostUSD, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                }
            }
            if let failure = run.failureSummary {
                Text(failure).font(DS.Text.micro).foregroundStyle(DS.Colour.failed).lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.md + 1)
        .padding(.vertical, DS.Space.sm + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colour(for run: TraceReader.Run) -> Color {
        switch run.manifest?.outcome {
        case .succeeded:          return DS.Colour.done
        case .failed, .timedOut:  return DS.Colour.failed
        case .refused:            return DS.Colour.running
        case .cancelled:          return DS.Colour.inkTertiary
        case .none:               return run.failureSummary == nil ? DS.Colour.inkTertiary : DS.Colour.failed
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let run = selected {
            VStack(spacing: 0) {
                header(run)
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.sm + 1) {
                        ForEach(timeline) { StepRow(entry: $0) }
                    }
                    .padding(DS.Space.lg + 2)
                }
            }
        } else {
            EmptyState(systemImage: "sidebar.left",
                       title: "Select a run",
                       message: "Pick one on the left to see every step it took.")
        }
    }

    private func header(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(run.manifest?.goal ?? run.id)
                .font(DS.Text.title).foregroundStyle(DS.Colour.ink)
            HStack(spacing: DS.Space.lg) {
                if let manifest = run.manifest {
                    metadata("bot", manifest.botName)
                    metadata("brain", manifest.brain)
                    metadata("tokens", "\(manifest.totalPromptTokens + manifest.totalCompletionTokens)")
                    if manifest.totalCostUSD > 0 {
                        metadata("cost", String(format: "$%.4f", manifest.totalCostUSD))
                    }
                }
                chainBadge(run.chain)
                Spacer()
                SecondaryButton("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([run.directory])
                }
            }
            if let note = run.manifest?.closingNote, !note.isEmpty {
                Text(note)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }

    private func metadata(_ name: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(name).font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
            Text(value).font(DS.Text.micro).foregroundStyle(DS.Colour.inkSecondary)
        }
    }

    /// A hash chain nobody checks is decoration. This checks it every time a run is opened.
    @ViewBuilder private func chainBadge(_ status: TraceWriter.ChainStatus) -> some View {
        switch status {
        case .intact(let records):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "lock.fill").font(DS.Text.glyphTiny)
                Text("\(records) records intact").font(DS.Text.micro)
            }
            .foregroundStyle(DS.Colour.done)
        case .brokenAt(let line, let reason):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark").font(DS.Text.glyphTiny)
                Text("altered at line \(line) — \(reason)").font(DS.Text.micro)
            }
            .foregroundStyle(DS.Colour.failed)
        case .unreadable:
            Text("record unreadable").font(DS.Text.micro).foregroundStyle(DS.Colour.failed)
        }
    }
}

// MARK: - One step

private struct StepRow: View {
    let entry: TraceReader.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Text("\(entry.seq)")
                    .font(DS.Text.mono(DS.Text.Scale.micro))
                    .foregroundStyle(DS.Colour.inkTertiary)
                    .frame(width: DS.Space.xxl - 2, alignment: .trailing)

                Image(systemName: icon)
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(tint)
                    .frame(width: DS.Space.lg + 2)

                VStack(alignment: .leading, spacing: DS.Space.xs - 1) {
                    Text(entry.summary)
                        .font(DS.Text.secondary)
                        .foregroundStyle(DS.Colour.ink)
                        .lineLimit(expanded ? nil : 2)

                    // The model's stated reason for this step — the "decision" in decision trace.
                    if let intent = entry.intent, intent != entry.summary {
                        Text(intent)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Colour.inkSecondary)
                            .lineLimit(expanded ? nil : 1)
                    }

                    if let permission = entry.permission {
                        HStack(spacing: DS.Space.xs + 1) {
                            Image(systemName: permissionIcon(permission.outcome))
                                .font(DS.Text.glyphTiny)
                            Text("\(permission.outcome) — \(permission.reason)")
                                .font(DS.Text.micro)
                        }
                        .foregroundStyle(permission.outcome == "refused"
                                         ? DS.Colour.failed : DS.Colour.inkTertiary)
                    }

                    if let error = entry.error, !error.isEmpty {
                        Text(error)
                            .font(DS.Text.mono(DS.Text.Scale.caption))
                            .foregroundStyle(DS.Colour.failed)
                            .lineLimit(expanded ? nil : 2)
                    }
                }
                Spacer(minLength: DS.Space.sm)

                if entry.tokens > 0 {
                    Text("\(entry.tokens) tok")
                        .font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                }
                Text(entry.at, format: .dateTime.hour().minute().second())
                    .font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
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
        .padding(DS.Space.lg - 2)
        .background(DS.Colour.raised, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.surface) { expanded.toggle() } }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs - 1) {
            Text(title).font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
            Text(text)
                .font(DS.Text.mono())
                .foregroundStyle(DS.Colour.inkSecondary)
                .textSelection(.enabled)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colour.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .padding(.leading, DS.Space.xxl + DS.Space.xl + 2)
    }

    private func permissionIcon(_ outcome: String) -> String {
        switch outcome {
        case "allowed": return "checkmark.shield"
        case "asked":   return "hand.raised"
        default:        return "nosign"
        }
    }

    private var icon: String {
        switch entry.kind {
        case .runStarted:               return "play.circle"
        case .runFinished:              return "flag.checkered"
        case .modelCall, .modelResponse: return "brain"
        case .toolProposed:             return "wrench.and.screwdriver"
        case .permissionCheck:          return "hand.raised"
        case .verification:             return "checkmark.seal"
        case .stuckDetected:            return "exclamationmark.triangle"
        case .recovery:                 return "arrow.uturn.backward"
        case .screenshot:               return "camera"
        case .userMessage:              return "person"
        default:                        return "circle"
        }
    }

    private var tint: Color {
        if entry.error != nil { return DS.Colour.failed }
        if entry.permission?.outcome == "refused" { return DS.Colour.failed }
        if entry.kind == .stuckDetected { return DS.Colour.running }
        if entry.outcome == .succeeded { return DS.Colour.done }
        return DS.Colour.inkTertiary
    }
}
